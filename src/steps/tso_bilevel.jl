using .Networks

using Dates
using JuMP
using Printf
using Parameters

@with_kw struct TSOBilevel <: AbstractTSO
    configs::TSOBilevelConfigs = TSOBilevelConfigs()
end

function run(runnable::TSOBilevel, ech::Dates.DateTime, firmness, TS::Vector{Dates.DateTime}, context::AbstractContext)
    problem_name_l = @sprintf("tso_bilevel_%s", ech)

    runnable.configs.out_path = context.out_dir
    runnable.configs.problem_name = problem_name_l

    return tso_bilevel(get_network(context),
                    TS,
                    get_generators_initial_state(context),
                    get_scenarios(context, ech),
                    get_uncertainties(context, ech),
                    firmness,
                    get_market_schedule(context),
                    get_tso_schedule(context),
                    runnable.configs
                    )
end

function update_tso_schedule!(context::AbstractContext, ech, result::TSOBilevelModel, firmness,
                            runnable::TSOBilevel)
    tso_schedule = get_tso_schedule(context)
    tso_schedule.decider_type = DeciderType(runnable)
    tso_schedule.decision_time = ech

    # upper problem (TSO) locates limitable injections
    for ((gen_id, ts, s), p_injected_var) in result.upper.limitable_model.p_injected
        set_prod_value!(tso_schedule, gen_id, ts, s, value(p_injected_var))
    end
    # lower problem (Market) decides imposable injections
    for ((gen_id, ts, s), p_injected_var) in result.lower.imposable_model.p_injected
        if get_power_level_firmness(firmness, gen_id, ts) == FREE
            set_prod_value!(tso_schedule, gen_id, ts, s, value(p_injected_var))
        elseif get_power_level_firmness(firmness, gen_id, ts) == TO_DECIDE
            set_prod_definitive_value!(tso_schedule, gen_id, ts, value(p_injected_var))
        elseif get_power_level_firmness(firmness, gen_id, ts) == DECIDED
            @assert( value(p_injected_var) ≈ get_prod_value(tso_schedule, gen_id, ts) )
        end
    end

    for ((gen_id, ts, s), b_on_var) in result.upper.imposable_model.b_on
        gen_state_value = parse(GeneratorState, value(b_on_var))
        if get_commitment_firmness(firmness, gen_id, ts) == FREE
            set_commitment_value!(tso_schedule, gen_id, ts, s, gen_state_value)
        elseif get_commitment_firmness(firmness, gen_id, ts) in [TO_DECIDE, DECIDED]
            set_commitment_definitive_value!(tso_schedule, gen_id, ts, gen_state_value)
        end
    end

    # Capping : upper problem (TSO) locates cappings
    update_schedule_capping!(tso_schedule, result.upper.limitable_model)

    # cut_conso (load-shedding) : upper problem (TSO) locates load shedding
    update_schedule_cut_conso!(tso_schedule, result.upper.slack_model)

    return tso_schedule
end

function update_schedule_capping!(tso_schedule, limitable_model::TSOBilevelTSOLimitableModel)
    reset_capping!(tso_schedule)

    for ((gen_id, ts, s), p_capping_var) in limitable_model.p_capping
        tso_schedule.capping[gen_id, ts, s] = value(p_capping_var)
    end
end

function update_schedule_cut_conso!(tso_schedule, slack_model::TSOBilevelTSOSlackModel)
    reset_cut_conso_by_bus!(tso_schedule)

    for ((bus_id, ts, s), p_cut_conso_var) in slack_model.p_cut_conso
        tso_schedule.cut_conso_by_bus[bus_id, ts, s] = value(p_cut_conso_var)
    end
end


function update_tso_actions!(context::AbstractContext, ech, result, firmness,
                            runnable::TSOBilevel)
    tso_actions = get_tso_actions(context)
    reset_tso_actions!(tso_actions)

    # Limitations : only firm i.e. value is common to all scenarios
    limitations = SortedDict{Tuple{String,DateTime}, Float64}() #TODELETE
    for ((gen_id, ts, s), p_limit_var) in result.upper.limitable_model.p_limit
        if (value(result.upper.limitable_model.b_is_limited[gen_id, ts, s]) > 1e-09)
            if ( get_power_level_firmness(firmness, gen_id, ts) in [TO_DECIDE, DECIDED]
                || runnable.configs.LINK_SCENARIOS_LIMIT )
                @assert( value(p_limit_var) ≈ get!(limitations, (gen_id, ts), value(p_limit_var)) ) #TODELETE : checks that all values are the same across scenarios
                set_limitation_value!(tso_actions, gen_id, ts, value(p_limit_var))
            else
                #FIXME : may encounter problems if runnable.configs.LINK_SCENARIOS_LIMIT==false, cause limitations are supposed firm
                @warn "FIXME? : need to fix limitation actions to a by scenario before DP"
            end
        #else : will remain missing
        end
    end

    # Impositions
    impositions = SortedDict{Tuple{String,DateTime}, Float64}() #TODELETE
    for ((gen_id, ts, s), p_injected_var) in result.lower.imposable_model.p_injected
        p_min_var = result.upper.imposable_model.p_tso_min[gen_id, ts, s]
        p_max_var = result.upper.imposable_model.p_tso_max[gen_id, ts, s]

        if get_power_level_firmness(firmness, gen_id, ts) in [TO_DECIDE, DECIDED]
            @assert( value(p_injected_var) ≈ get!(impositions, (gen_id, ts), value(p_injected_var)) ) #TODELETE : checks that all values are the same across scenarios
            set_imposition_value!(tso_actions, gen_id, ts, s, value(p_injected_var), value(p_injected_var))
        else
            set_imposition_value!(tso_actions, gen_id, ts, s, value(p_min_var), value(p_max_var))
        end
    end

    # Commitments : only after DMO
    commitments = SortedDict{Tuple{String,DateTime}, GeneratorState}() #TODELETE
    for ((gen_id, ts, s), b_on_var) in result.upper.imposable_model.b_on
        if get_commitment_firmness(firmness, gen_id, ts) in [TO_DECIDE, DECIDED]
            gen_state_value = parse(GeneratorState, value(b_on_var))
            @assert( gen_state_value == get!(commitments, (gen_id, ts), gen_state_value) ) #TODELETE : checks that all values are the same across scenarios
            set_commitment_value!(tso_actions, gen_id, ts, gen_state_value)
        end
    end
end
