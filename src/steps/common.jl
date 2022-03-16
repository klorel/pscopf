using .Networks

using JuMP
using Dates

try
    using Xpress;
    global OPTIMIZER = Xpress.Optimizer
catch e_xpress
    if isa(e_xpress, ArgumentError)
        try
            using CPLEX;
            global OPTIMIZER = CPLEX.Optimizer
        catch e_cplex
            if isa(e_cplex, ArgumentError)
                using Cbc;
                global OPTIMIZER = Cbc.Optimizer
            else
                throw(e_cplex)
            end
        end
    else
        throw(e_xpress)
    end
end

"""
Possible status values for a pscopf model container

    - pscopf_OPTIMAL : a solution that does not use slacks was retrieved
    - pscopf_INFEASIBLE : no solution was retrieved
    - pscopf_FEASIBLE : non-optimal solution was retrieved
    - pscopf_UNSOLVED : model is not solved yet
"""
@enum PSCOPFStatus begin
    pscopf_OPTIMAL
    pscopf_INFEASIBLE
    pscopf_FEASIBLE
    pscopf_UNSOLVED
end


abstract type AbstractModelContainer end

function get_model(model_container::AbstractModelContainer)::Model
    return model_container.model
end

function get_status(model_container_p::AbstractModelContainer)::PSCOPFStatus
    solver_status_l = termination_status(get_model(model_container_p))

    if solver_status_l == OPTIMIZE_NOT_CALLED
        return pscopf_UNSOLVED
    elseif solver_status_l == INFEASIBLE
        @error "model status is infeasible!"
        return pscopf_INFEASIBLE
    elseif solver_status_l == OPTIMAL
        return pscopf_OPTIMAL
    else
        @warn "solver termination status was not optimal : $(solver_status_l)"
        return pscopf_FEASIBLE
    end
end

function solve!(model::Model,
                problem_name="problem", out_folder=nothing,
                optimizer=OPTIMIZER)
    problem_name_l = replace(problem_name, ":"=>"_")
    set_optimizer(model, optimizer);

    if !isnothing(out_folder)
        mkpath(out_folder)
        model_file_l = joinpath(out_folder, problem_name_l*".lp")
        write_to_file(model, model_file_l)

        log_file_l = joinpath(out_folder, problem_name_l*".log")
    else
        log_file_l = devnull
    end

    redirect_to_file(log_file_l) do
        optimize!(model)
    end
end


abstract type AbstractGeneratorModel end
abstract type AbstractImposableModel <: AbstractGeneratorModel end
abstract type AbstractLimitableModel <: AbstractGeneratorModel end

abstract type AbstractSlackModel end

abstract type AbstractObjectiveModel end


# AbstractGeneratorModel
############################

function add_p_injected!(generator_model::AbstractGeneratorModel, model::Model,
                        gen_id::String, ts::DateTime, s::String,
                        p_max::Float64,
                        force_to_max::Bool
                        )
    name =  @sprintf("P_injected[%s,%s,%s]", gen_id, ts, s)

    if force_to_max
        generator_model.p_injected[gen_id, ts, s] = @variable(model, base_name=name,
                                                        lower_bound=p_max, upper_bound=p_max)
    else
        generator_model.p_injected[gen_id, ts, s] = @variable(model, base_name=name,
                                                        lower_bound=0., upper_bound=p_max)
    end

    return generator_model.p_injected[gen_id, ts, s]
end

function sum_injections(generator_model::AbstractGeneratorModel,
                        ts::Dates.DateTime, s::String)::AffExpr
    sum_l = AffExpr(0)
    for ((_,ts_l,s_l), var_l) in generator_model.p_injected
        if (ts_l,s_l) == (ts, s)
            sum_l += var_l
        end
    end
    return sum_l
end

# AbstractLimitableModel
############################

function add_p_limit!(limitable_model::AbstractLimitableModel, model::Model,
                        gen_id::String, ts::Dates.DateTime,
                        scenarios::Vector{String},
                        pmax,
                        inject_uncertainties::InjectionUncertainties,
                        decision_firmness::DecisionFirmness, #by ts
                        preceding_limit::Union{Float64, Missing}
                        )
    b_is_limited = limitable_model.b_is_limited
    p_limit_x_is_limited = limitable_model.p_limit_x_is_limited

    name =  @sprintf("P_limit[%s,%s]", gen_id, ts)
    limitable_model.p_limit[gen_id, ts] = @variable(model, base_name=name, lower_bound=0., upper_bound=pmax)
    limit_var = limitable_model.p_limit[gen_id, ts]
    for s in scenarios
        injection_var = limitable_model.p_injected[gen_id, ts, s]

        name =  @sprintf("B_is_limited[%s,%s,%s]", gen_id, ts, s)
        b_is_limited[gen_id, ts, s] = @variable(model, base_name=name, binary=true)

        name =  @sprintf("P_limit_x_is_limited[%s,%s,%s]", gen_id, ts, s)
        p_limit_x_is_limited[gen_id, ts, s] = add_prod_vars!(model,
                                                            limit_var,
                                                            b_is_limited[gen_id, ts, s],
                                                            pmax,
                                                            name
                                                            )

        #inj[g,ts,s] = min{p_limit[g,ts], uncertainties(g,ts,s), pmax(g)}
        @constraint(model, injection_var <= limit_var)
        p_enr = min(get_uncertainties(inject_uncertainties, ts, s), pmax)
        @constraint(model, injection_var ==
                        (1-b_is_limited[gen_id, ts, s]) * p_enr + p_limit_x_is_limited[gen_id, ts, s]
                        )
    end

    if decision_firmness==DECIDED
        # Limit cannot bechanged once it was fixed
        # FIXME : maybe allow decreasing ? limit_var <= preceding_limit
        @assert !ismissing(preceding_limit)
        @constraint(model, limit_var == preceding_limit)
    end

    return limitable_model, model
end

# AbstractImposableModel
############################

function add_commitment!(imposable_model::AbstractImposableModel, model::Model,
                        generator::Networks.Generator,
                        target_timepoints::Vector{Dates.DateTime},
                        scenarios::Vector{String},
                        generator_initial_state::GeneratorState
                        )
    p_injected_vars = imposable_model.p_injected
    b_on_vars = imposable_model.b_on
    b_start_vars = imposable_model.b_start

    gen_id = Networks.get_id(generator)
    p_max = Networks.get_p_max(generator)
    p_min = Networks.get_p_min(generator)
    for s in scenarios
        for (ts_index, ts) in enumerate(target_timepoints)
            name =  @sprintf("B_on[%s,%s,%s]", gen_id, ts, s)
            b_on_vars[gen_id, ts, s] = @variable(model, base_name=name, binary=true)
            name =  @sprintf("B_start[%s,%s,%s]", gen_id, ts, s)
            b_start_vars[gen_id, ts, s] = @variable(model, base_name=name, binary=true)

            # pmin < P_injected < pmax OR = 0
            @constraint(model, p_injected_vars[gen_id, ts, s] <= p_max * b_on_vars[gen_id, ts, s]);
            @constraint(model, p_injected_vars[gen_id, ts, s] >= p_min * b_on_vars[gen_id, ts, s]);

            #commitment_constraints
            preceding_on = (ts_index > 1) ? b_on_vars[gen_id, target_timepoints[ts_index-1], s] : float(generator_initial_state)
            @constraint(model, b_start_vars[gen_id, ts, s] <= b_on_vars[gen_id, ts, s])
            @constraint(model, b_start_vars[gen_id, ts, s] <= 1 - preceding_on)
            @constraint(model, b_start_vars[gen_id, ts, s] >= b_on_vars[gen_id, ts, s] - preceding_on)
        end
    end

    return imposable_model, model
end

# Utils
##################

function link_scenarios!(model::Model, vars::AbstractDict{Tuple{String,DateTime,String},VariableRef},
                        gen_id::String, ts::DateTime, scenarios::Vector{String})
    s1 = scenarios[1]
    for (s_index, s) in enumerate(scenarios)
        if s_index > 1
            @constraint(model, vars[gen_id, ts, s] == vars[gen_id, ts, s1]);
        end
    end
    return model
end

function add_commitment_firmness_constraints!(model::Model,
                                            generator::Networks.Generator,
                                            b_on_vars::SortedDict{Tuple{String,DateTime,String},VariableRef},
                                            b_start_vars::SortedDict{Tuple{String,DateTime,String},VariableRef},
                                            target_timepoints::Vector{Dates.DateTime},
                                            scenarios::Vector{String},
                                            generator_initial_state::GeneratorState,
                                            commitment_firmness::SortedDict{Dates.DateTime, DecisionFirmness}, #by ts
                                            generator_reference_schedule::GeneratorSchedule
                                            )
    gen_id = Networks.get_id(generator)
    preceding_ts = nothing
    for ts in target_timepoints
        if commitment_firmness[ts] in [DECIDED, TO_DECIDE]
            link_scenarios!(model, b_on_vars, gen_id, ts, scenarios)
            link_scenarios!(model, b_start_vars, gen_id, ts, scenarios)
        end

        if commitment_firmness[ts] == DECIDED
            reference_start_val = get_start_value(generator_reference_schedule, ts, preceding_ts, generator_initial_state)
            if reference_start_val == 0
                for s in scenarios
                    @constraint(model, b_start_vars[gen_id, ts, s] == 0)
                    @constraint(model, b_start_vars[gen_id, ts, s] == 0)
                end
            end

            reference_on_val = float(safeget_commitment_value(generator_reference_schedule, ts))
            if reference_on_val < 1e-09
                for s in scenarios
                    @constraint(model, b_on_vars[gen_id, ts, s] == 0)
                    @constraint(model, b_on_vars[gen_id, ts, s] == 0)
                end
            end
        end
        preceding_ts = ts
    end

    return model
end

function add_power_level_firmness_constraints!(model::Model,
                                                generator::Networks.Generator,
                                                p_injected_vars::SortedDict{Tuple{String,DateTime,String},VariableRef},
                                                target_timepoints::Vector{Dates.DateTime},
                                                scenarios::Vector{String},
                                                power_level_firmness::SortedDict{Dates.DateTime, DecisionFirmness}, #by ts
                                                generator_reference_schedule::GeneratorSchedule
                                                )
    gen_id = Networks.get_id(generator)
    for ts in target_timepoints
        if power_level_firmness[ts] in [DECIDED, TO_DECIDE]
            link_scenarios!(model, p_injected_vars, gen_id, ts, scenarios)
        end

        if power_level_firmness[ts] == DECIDED
            val = safeget_prod_value(generator_reference_schedule,ts)
            for s in scenarios
                @assert( !has_upper_bound(p_injected_vars[gen_id, ts, s]) || (val <= upper_bound(p_injected_vars[gen_id, ts, s])) )
                @constraint(model, p_injected_vars[gen_id, ts, s] == val)
            end
        end
    end

    return model
end


"""
    add_prod_vars!
adds to the model and returns a variable that represents the product expression (noted var_a_x_b):
   var_a * var_b where var_b is a binary variable, and var_a is a positive real variable bound by M
The following constraints are added to the model :
    var_a_x_b <= var_a
    var_a_x_b <= M * var_b
    M*(1 - var_b) + var_a_x_b >= var_a
"""
function add_prod_vars!(model::Model,
                        var_a::VariableRef,
                        var_binary::VariableRef,
                        M,
                        name
                        )
    if !is_binary(var_binary)
        throw(error("variable var_binary needs to be binary to express the product!"))
    end
    if lower_bound(var_a) < 0
        throw(error("variable var_a needs to be positive to express the product!"))
    end

    var_a_x_b = @variable(model, base_name=name, lower_bound=0., upper_bound=M)
    @constraint(model, var_a_x_b <= var_a)
    @constraint(model, var_a_x_b <= M * var_binary)
    @constraint(model, M*(1-var_binary) + var_a_x_b >= var_a)

    return var_a_x_b
end

