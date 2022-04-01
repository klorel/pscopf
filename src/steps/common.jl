using .Networks

using JuMP
using BilevelJuMP
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
    pscopf_HAS_SLACK
    pscopf_UNSOLVED
end


abstract type AbstractModelContainer end

abstract type AbstractGeneratorModel end
abstract type AbstractImposableModel <: AbstractGeneratorModel end
abstract type AbstractLimitableModel <: AbstractGeneratorModel end

abstract type AbstractSlackModel end

abstract type AbstractObjectiveModel end

# TODO : use a proper struct for by scenario variables
# eg: UncertainValue{VariableRef}
# or maybe a similar other struct cause depending on "ech"
#    we either will need by scenario vars (eg. injection/commitment before DP/DMO for imposables)
#    or we will need one variable (eg. injection at or after DP for imposables)
# if need a firm value (at/after DP or DMO) call a link_scenarios(::AbstractModel, ::)
# which adds @constraint(model, by_scenario_vars[s] == firm_variable)
# or maybe no need to if we create a single variable for scenarios right from the beginning
# and have proper getters too get_var(::, s) -> scenario's var or missing
# and have proper getters too get_var(::) -> firm var or error

struct BilevelModelContainer{U,L} <: AbstractModelContainer
    model::BilevelModel
    upper::U
    lower::L
end

# AbstractModelContainer
###########################

function get_model(model_container::AbstractModelContainer)::AbstractModel
    return model_container.model
end

function get_status(model_container_p::AbstractModelContainer)::PSCOPFStatus
    solver_status_l = termination_status(get_model(model_container_p))

    if solver_status_l == MOI.OPTIMIZE_NOT_CALLED
        return pscopf_UNSOLVED
    elseif solver_status_l == MOI.INFEASIBLE
        @error "model status is infeasible!"
        return pscopf_INFEASIBLE
    elseif solver_status_l == MOI.OPTIMAL
        if has_positive_slack(model_container_p)
            @warn "model solved optimally but slack variables were used!"
            return pscopf_HAS_SLACK
        else
            return pscopf_OPTIMAL
        end
    else
        @warn "solver termination status was not optimal : $(solver_status_l)"
        return pscopf_FEASIBLE
    end
end

function solve!(model::BilevelModel,
                problem_name="problem", out_folder=nothing)
    problem_name_l = replace(problem_name, ":"=>"_")
    BilevelJuMP.set_mode(model, BilevelJuMP.IndicatorMode())
    # BilevelJuMP.set_mode(model, BilevelJuMP.SOS1Mode())

    lower_file = ""
    upper_file = ""
    bilevel_file = ""
    solver_file = ""
    if !isnothing(out_folder)
        mkpath(out_folder)
        lower_file  = joinpath(out_folder, "lower_"*problem_name_l*".lp")
        upper_file = joinpath(out_folder, "upper_"*problem_name_l*".lp")
        #bilevel_file = joinpath(out_folder, problem_name_l*".lp") #buged?
        # solver_file = joinpath(out_folder, "solver_"*problem_name_l*".lp") #buged?

        log_file_l = joinpath(out_folder, problem_name_l*".log")
    else
        log_file_l = devnull
    end

    println(typeof(model))
    println(typeof(model.upper))
    println(typeof(model.lower))
    println(typeof(Upper(model)))
    println(typeof(Lower(model)))

    redirect_to_file(log_file_l) do
        optimize!(model,
                lower_prob=lower_file, upper_prob=upper_file,
                bilevel_prob=bilevel_file,
                solver_prob=solver_file)
    end

    @info "Lower objective value : $(objective_value(Lower(model)))"

    return model
end

function solve!(model::AbstractModel,
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

    return model
end

function solve!(model_container::AbstractModelContainer, problem_name, out_path)
    model_l = get_model(model_container)

    @info problem_name
    solve!(model_l, problem_name, out_path)
    @info "pscopf model status: $(get_status(model_container))"
    @info "Termination status : $(termination_status(model_l))"
    @info "Objective value : $(objective_value(model_l))"

    return model_container
end

function get_p_injected(model_container, type::Networks.GeneratorType)
    if type == Networks.LIMITABLE
        return model_container.limitable_model.p_injected
    elseif type == Networks.IMPOSABLE
        return model_container.imposable_model.p_injected
    end
    return nothing
end

function has_positive_slack(model_container)::Bool
    error("unimplemented")
end

# AbstractGeneratorModel
############################

function add_p_injected!(generator_model::AbstractGeneratorModel, model::AbstractModel,
                        gen_id::String, ts::DateTime, s::String,
                        p_max::Float64,
                        force_to_max::Bool
                        )::AbstractVariableRef
    name =  @sprintf("P_injected[%s,%s,%s]", gen_id, ts, s)
    println(typeof(generator_model.p_injected))

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
    ids::AbstractArray, ts::Dates.DateTime, s::String)::AffExpr
    error("TODO")
    for id in ids
        #...
    end
end
function sum_injections(generator_model::AbstractGeneratorModel,
                        ts::Dates.DateTime, s::String)
    sum_l = 0.
    for ((_,ts_l,s_l), var_l) in generator_model.p_injected
        if (ts_l,s_l) == (ts, s)
            sum_l += var_l
        end
    end
    return sum_l
end

# AbstractLimitableModel
############################
function add_p_limit!(limitable_model::AbstractLimitableModel, model::AbstractModel,
                        gen_id::String, ts::Dates.DateTime,
                        scenarios::Vector{String},
                        pmax,
                        inject_uncertainties::InjectionUncertainties,
                        decision_firmness::DecisionFirmness, #by ts
                        always_link_scenarios=false
                        )
    b_is_limited = limitable_model.b_is_limited
    p_limit_x_is_limited = limitable_model.p_limit_x_is_limited
    p_limit = limitable_model.p_limit

    for s in scenarios
        name =  @sprintf("P_limit[%s,%s,%s]", gen_id, ts, s)
        p_limit[gen_id, ts, s] = @variable(model, base_name=name, lower_bound=0., upper_bound=pmax)

        injection_var = limitable_model.p_injected[gen_id, ts, s]

        name =  @sprintf("B_is_limited[%s,%s,%s]", gen_id, ts, s)
        b_is_limited[gen_id, ts, s] = @variable(model, base_name=name, binary=true)

        name =  @sprintf("P_limit_x_is_limited[%s,%s,%s]", gen_id, ts, s)
        p_limit_x_is_limited[gen_id, ts, s] = add_prod_vars!(model,
                                                            p_limit[gen_id, ts, s],
                                                            b_is_limited[gen_id, ts, s],
                                                            pmax,
                                                            name
                                                            )

        #inj[g,ts,s] = min{p_limit[g,ts,s], uncertainties(g,ts,s), pmax(g)}
        name = @sprintf("c1_pinj_lim[%s,%s,%s]",gen_id,ts,s)
        @constraint(model, injection_var <= p_limit[gen_id, ts, s], base_name = name)
        name = @sprintf("c2_pinj_lim[%s,%s,%s]",gen_id,ts,s)
        p_enr = min(get_uncertainties(inject_uncertainties, ts, s), pmax)
        @constraint(model, injection_var ==
                        (1-b_is_limited[gen_id, ts, s]) * p_enr + p_limit_x_is_limited[gen_id, ts, s],
                    base_name = name)
    end

    # NOTE : DECIDED here does not hold its meaning. FIRM is more expressive.
    #       p_limit can always be changed in the future horizons (it is not really decided)
    #DECIDED indicates that we are past the limitable's DP => need a common decision for all scenarios
    if always_link_scenarios || (decision_firmness in [DECIDED, TO_DECIDE])
        link_scenarios!(model, p_limit, gen_id, ts, scenarios)
    end

    return limitable_model, model
end

# AbstractImposableModel
############################
function add_commitment_constraints!(model::AbstractModel,
                                    b_on_vars::SortedDict{Tuple{String,DateTime,String},VariableRef},
                                    b_start_vars::SortedDict{Tuple{String,DateTime,String},VariableRef},
                                    gen_id::String,
                                    target_timepoints::Vector{Dates.DateTime},
                                    scenarios::Vector{String},
                                    generator_initial_state::GeneratorState)
    for s in scenarios
        for (ts_index, ts) in enumerate(target_timepoints)
            preceding_on = (ts_index > 1) ? b_on_vars[gen_id, target_timepoints[ts_index-1], s] : float(generator_initial_state)
            @constraint(model, b_start_vars[gen_id, ts, s] <= b_on_vars[gen_id, ts, s])
            @constraint(model, b_start_vars[gen_id, ts, s] <= 1 - preceding_on)
            @constraint(model, b_start_vars[gen_id, ts, s] >= b_on_vars[gen_id, ts, s] - preceding_on)
        end
    end
    return model
end
function add_commitment!(imposable_model::AbstractImposableModel, model::AbstractModel,
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
        for ts in target_timepoints
            name =  @sprintf("B_on[%s,%s,%s]", gen_id, ts, s)
            b_on_vars[gen_id, ts, s] = @variable(model, base_name=name, binary=true)
            name =  @sprintf("B_start[%s,%s,%s]", gen_id, ts, s)
            b_start_vars[gen_id, ts, s] = @variable(model, base_name=name, binary=true)

            # pmin < P_injected < pmax OR = 0
            @constraint(model, p_injected_vars[gen_id, ts, s] <= p_max * b_on_vars[gen_id, ts, s]);
            @constraint(model, p_injected_vars[gen_id, ts, s] >= p_min * b_on_vars[gen_id, ts, s]);
        end
    end

    #commitment_constraints : link b_start and b_on
    add_commitment_constraints!(model,
                                b_on_vars, b_start_vars,
                                gen_id, target_timepoints, scenarios, generator_initial_state)

    return imposable_model, model
end

# Objective
##################

function add_imposable_start_cost!(obj_component::AffExpr,
                                b_start::AbstractDict{T,V}, network, gratis_starts) where T <: Tuple where V <: VariableRef
    for ((gen_id,ts,_), b_start_var) in b_start
        if (gen_id,ts) in gratis_starts
            @debug(@sprintf("ignore starting cost of %s at %s", gen_id, ts))
            continue
        end
        generator = Networks.get_generator(network, gen_id)
        gen_start_cost = Networks.get_start_cost(generator)
        add_to_expression!(obj_component,
                            b_start_var * gen_start_cost)
    end

    return obj_component
end

function add_limitable_prop_cost!(obj_component::AffExpr,
                                p_injected::AbstractDict{T,V}, network)  where T <: Tuple where V <: VariableRef
    for ((gen_id,_,_), p_injected_var) in p_injected
        generator = Networks.get_generator(network, gen_id)
        gen_prop_cost = Networks.get_prop_cost(generator)
        add_to_expression!(obj_component,
                            p_injected_var * gen_prop_cost)
    end

    return obj_component
end

function add_imposable_prop_cost!(obj_component::AffExpr,
                                p_injected::AbstractDict{T,V}, network)  where T <: Tuple where V <: VariableRef
    for ((gen_id,_,_), p_injected_var) in p_injected
        generator = Networks.get_generator(network, gen_id)
        gen_prop_cost = Networks.get_prop_cost(generator)
        add_to_expression!(obj_component,
                            p_injected_var * gen_prop_cost)
    end

    return obj_component
end

function add_coeffxsum_cost!(obj_component::AffExpr,
                            vars_dict::AbstractDict{T,V}, coeff::Float64)  where T <: Tuple where V <: VariableRef
    for (_, var_l) in vars_dict
        add_to_expression!(obj_component, coeff * var_l)
    end

    return obj_component
end


# AbstractSlackModel
############################

function has_positive_value(dict_vars::AbstractDict{T,V}) where T where V <: AbstractVariableRef
    return any(e -> value(e[2]) > 1e-09, dict_vars)
    #e.g. 1e-15 is supposed to be 0.
end

function add_cut_conso_by_bus!(model::AbstractModel, p_cut_conso,
                                buses,
                                target_timepoints::Vector{Dates.DateTime},
                                scenarios::Vector{String},
                                uncertainties_at_ech::UncertaintiesAtEch
                                )
    for ts in target_timepoints
        for s in scenarios
            for bus in buses
                bus_id = Networks.get_id(bus)
                name =  @sprintf("P_cut_conso[%s,%s,%s]", bus_id, ts, s)
                load = get_uncertainties(uncertainties_at_ech, bus_id, ts, s)
                p_cut_conso[bus_id, ts, s] = @variable(model, base_name=name,
                                                            lower_bound=0., upper_bound=load)
            end
        end
    end
    return p_cut_conso
end

# Utils
##################

function link_scenarios!(model::AbstractModel, vars::AbstractDict{Tuple{String,DateTime,String},V},
                        gen_id::String, ts::DateTime, scenarios::Vector{String}) where V<:AbstractVariableRef
    s1 = scenarios[1]
    for (s_index, s) in enumerate(scenarios)
        if s_index > 1
            @constraint(model, vars[gen_id, ts, s] == vars[gen_id, ts, s1]);
        end
    end
    return model
end

function add_keep_off_constraint(model::AbstractModel, b_on_vars, b_start_vars,
                                gen_id, ts, scenarios)
    for s in scenarios
        @constraint(model, b_on_vars[gen_id, ts, s] == 0)
        @constraint(model, b_start_vars[gen_id, ts, s] == 0)
    end
    return model
end

function add_commitment_firmness_constraints!(model::AbstractModel,
                                            generator::Networks.Generator,
                                            b_on_vars::SortedDict{Tuple{String,DateTime,String},VariableRef},
                                            b_start_vars::SortedDict{Tuple{String,DateTime,String},VariableRef},
                                            target_timepoints::Vector{Dates.DateTime},
                                            scenarios::Vector{String},
                                            commitment_firmness::SortedDict{Dates.DateTime, DecisionFirmness}, #by ts
                                            generator_reference_schedule::GeneratorSchedule,
                                            commitment_actions::SortedDict{Tuple{String, Dates.DateTime}, GeneratorState}=SortedDict{Tuple{String, Dates.DateTime}, GeneratorState}(),
                                            always_link_scenarios::Bool=false
                                            )
    gen_id = Networks.get_id(generator)
    for ts in target_timepoints
        if always_link_scenarios || (commitment_firmness[ts] in [DECIDED, TO_DECIDE])
            link_scenarios!(model, b_on_vars, gen_id, ts, scenarios)
            link_scenarios!(model, b_start_vars, gen_id, ts, scenarios)
        end

        tso_action_commitment = get_commitment(commitment_actions, gen_id, ts)
        if !ismissing(tso_action_commitment)
            #TSO Actions OFF will be applied even if firmness is FREE
            if tso_action_commitment == OFF
                add_keep_off_constraint(model, b_on_vars, b_start_vars, gen_id, ts, scenarios)
            end
        elseif commitment_firmness[ts] == DECIDED
            reference_on_val = safeget_commitment_value(generator_reference_schedule, ts)
            if reference_on_val == OFF
                add_keep_off_constraint(model, b_on_vars, b_start_vars, gen_id, ts, scenarios)
            end
        end
    end

    return model
end

function freeze_vars!(model, p_injected_vars,
                        gen_id, ts, scenarios,
                        imposed_value::Float64)
    for s in scenarios
        @assert( !has_upper_bound(p_injected_vars[gen_id, ts, s]) || (imposed_value <= upper_bound(p_injected_vars[gen_id, ts, s])) )
        @constraint(model, p_injected_vars[gen_id, ts, s] == imposed_value)
    end
end

function add_power_level_firmness_constraints!(model::AbstractModel,
                                                generator::Networks.Generator,
                                                p_injected_vars::SortedDict{Tuple{String,DateTime,String},VariableRef},
                                                target_timepoints::Vector{Dates.DateTime},
                                                scenarios::Vector{String},
                                                power_level_firmness::SortedDict{Dates.DateTime, DecisionFirmness}, #by ts
                                                generator_reference_schedule::GeneratorSchedule,
                                                tso_actions::TSOActions=TSOActions()
                                                )
    @assert(Networks.get_type(generator) == Networks.IMPOSABLE)

    gen_id = Networks.get_id(generator)
    for ts in target_timepoints
        if power_level_firmness[ts] in [DECIDED, TO_DECIDE]
            link_scenarios!(model, p_injected_vars, gen_id, ts, scenarios)
        end

        imposition_level = get_imposition_level(tso_actions, gen_id, ts)
        tso_action_commitment = get_commitment(tso_actions, gen_id, ts)
        if ( !ismissing(tso_action_commitment) && tso_action_commitment==OFF )
            imposition_level = 0.
        elseif ( power_level_firmness[ts]==DECIDED && ismissing(imposition_level) )
            imposition_level = safeget_prod_value(generator_reference_schedule,ts)
        end
        if !ismissing(imposition_level)
            freeze_vars!(model, p_injected_vars, gen_id, ts, scenarios, imposition_level)
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
function add_prod_vars!(model::AbstractModel,
                        var_a::AbstractVariableRef,
                        var_binary::AbstractVariableRef,
                        M,
                        name
                        )::AbstractVariableRef
    if !is_binary(var_binary)
        throw(error("variable var_binary needs to be binary to express the product!"))
    end
    if lower_bound(var_a) < 0
        throw(error("variable var_a needs to be positive to express the product!"))
    end

    var_a_x_b = @variable(model, base_name=name, lower_bound=0., upper_bound=M)
    c_name = @sprintf("c1_%s",name)
    @constraint(model, var_a_x_b <= var_a, base_name=c_name)
    c_name = @sprintf("c2_%s",name)
    @constraint(model, var_a_x_b <= M * var_binary, base_name=c_name)
    c_name = @sprintf("c3_%s",name)
    @constraint(model, M*(1-var_binary) + var_a_x_b >= var_a, base_name=c_name)

    return var_a_x_b
end

