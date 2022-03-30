using Dates
using Parameters
using DataStructures

##########################################
## TSOActions
##########################################

@with_kw struct TSOActions
    #gen_id, ts => Float (values are firm)
    # Max allowed P of a limitable for a given ts
    limitations::SortedDict{Tuple{String, Dates.DateTime}, Float64} =
        SortedDict{Tuple{String, Dates.DateTime}, Float64}()
    # Imposed P bounds of an imposable for a given ts
    impositions::SortedDict{Tuple{String, Dates.DateTime}, Tuple{Float64,Float64}} =
        SortedDict{Tuple{String, Dates.DateTime}, Tuple{Float64,Float64}}()
    # Imposed commitment of a generator (with Pmin>0) for a given ts
    commitments::SortedDict{Tuple{String, Dates.DateTime}, GeneratorState} =
        SortedDict{Tuple{String, Dates.DateTime}, GeneratorState}()
end

## Limitations
#--------------

function get_limitations(tso_actions::TSOActions)
    return tso_actions.limitations
end
function get_limitations(limitations_dict::SortedDict{Tuple{String, Dates.DateTime}, Float64})
    return limitations_dict
end

function get_limitation(tso_actions, gen_id::String, ts::Dates.DateTime)::Union{Float64, Missing}
    limitations = get_limitations(tso_actions)
    if !haskey(limitations, (gen_id, ts))
        return missing
    else
        return limitations[gen_id, ts]
    end
end
function safeget_limitation(tso_actions, gen_id::String, ts::Dates.DateTime)::Union{Float64, Missing}
    limitation = get_limitation(tso_actions, gen_id, ts)
    if ismissing(limitation)
        msg = @sprintf("Missing limitation value for (gen_id=%s,ts=%s).", gen_id, ts)
        throw( error(msg) )
    else
        return limitations[gen_id, ts]
    end
end

function set_limitation_value!(tso_actions, gen_id::String, ts::Dates.DateTime, value::Float64)
    limitations = get_limitations(tso_actions)
    limitations[gen_id, ts] = value
end

## Impositions
#--------------

function get_impositions(tso_actions::TSOActions)
    return tso_actions.impositions
end


function get_impositions(impositions_dict::SortedDict{Tuple{String, Dates.DateTime}, Tuple{Float64,Float64}})
    return impositions_dict
end

function get_imposition(tso_actions, gen_id::String, ts::Dates.DateTime)::Union{Tuple{Float64,Float64}, Missing}
    impositions = get_impositions(tso_actions)
    if !haskey(impositions, (gen_id, ts))
        return missing
    else
        return impositions[gen_id, ts]
    end
end

function safeget_imposition(tso_actions, gen_id::String, ts::Dates.DateTime)::Tuple{Float64,Float64}
    imposition = get_imposition(tso_actions, gen_id, ts)
    if ismissing(imposition)
        msg = @sprintf("No imposition entry in TSOActions for (gen_id=%s,ts=%s).", gen_id, ts)
        throw(error(msg))
    else
        return imposition
    end
end

function get_imposition_level(tso_actions::TSOActions, gen_id::String, ts::Dates.DateTime)::Union{Float64, Missing}
    impositions = get_impositions(tso_actions)
    if !haskey(impositions, (gen_id, ts))
        return missing
    else
        value_min,value_max = impositions[gen_id, ts]
        if value_min != value_max
            msg = @sprintf("TSOActions for (gen_id=%s,ts=%s) imposes interval [%s,%s] and not a single power level.",
                            gen_id, ts, value_min, value_max)
            throw(error(msg))
        else
            return value_min
        end
    end
end

function set_imposition_value!(tso_actions, gen_id::String, ts::Dates.DateTime, value_min::Float64, value_max::Float64)
    impositions = get_impositions(tso_actions)
    impositions[gen_id, ts] = (value_min,value_max)
end

## Commitment
#--------------

function get_commitments(tso_actions)
    return tso_actions.commitments
end

function get_commitments(commitments_dict::SortedDict{Tuple{String, Dates.DateTime}, GeneratorState})
    return commitments_dict
end

function get_commitment(tso_actions, gen_id::String, ts::Dates.DateTime)::Union{GeneratorState, Missing}
    commitment = get_commitments(tso_actions)
    if !haskey(commitment, (gen_id, ts))
        return missing
    else
        return commitment[gen_id, ts]
    end
end

function safeget_commitment(tso_actions, gen_id::String, ts::Dates.DateTime)::GeneratorState
    commitment = get_commitment(tso_actions, gen_id, ts)
    if ismissing(commitment)
        msg = @sprintf("No commitment entry in TSOActions for (gen_id=%s,ts=%s).", gen_id, ts)
        throw(error(msg))
    else
        return commitment
    end
end

function set_commitment_value!(tso_actions, gen_id::String, ts::Dates.DateTime, value::GeneratorState)
    commitment = get_commitments(tso_actions)
    commitment[gen_id, ts] = value
end

function get_commitments(tso_actions, gen_id::String)
    gen_commitments = SortedDict{Dates.DateTime, GeneratorState}
    for ((gen_id_l,ts),commitment_val) in get_commitments(tso_actions)
        if gen_id_l == gen_id
            gen_commitments[ts] = commitment_val
        end
    end
    return gen_commitments
end

#######################
# Helpers
########################

"""
Performs a partial shallow copy of the input TSOActions
Modifying the returned tso_actions' kept attributes will modify the original one's.
"""
function filter_tso_actions(tso_actions::TSOActions;
                        keep_limitations::Bool=false,
                        keep_impositions::Bool=false,
                        keep_commitments::Bool=false)::TSOActions
    limitations_l = keep_limitations ? tso_actions.limitations : SortedDict{Tuple{String, Dates.DateTime}, Float64}()
    impositions_l = keep_impositions ? tso_actions.impositions : SortedDict{Tuple{String, Dates.DateTime}, Tuple{Float64,Float64}}()
    commitments_l = keep_commitments ? tso_actions.commitments : SortedDict{Tuple{String, Dates.DateTime}, GeneratorState}()

    return TSOActions(limitations_l, impositions_l, commitments_l)
end

function get_starts(tso_acions::TSOActions, initial_state::SortedDict{String, GeneratorState})
    return get_starts(get_commitments(tso_acions), initial_state)
end
function get_starts(commitments::SortedDict{Tuple{String, Dates.DateTime}, GeneratorState}, initial_state::SortedDict{String, GeneratorState})
    result = Set{Tuple{String,Dates.DateTime}}()

    preceding_id, preceding_state = nothing, nothing
    for ((gen_id,ts), gen_state) in commitments
        if ( isnothing(preceding_id) || gen_id!=preceding_id )
            preceding_state = initial_state[gen_id]
        end

        if get_start_value(preceding_state, gen_state) > 1e-09
            push!(result, (gen_id,ts) )
        end

        preceding_id = gen_id
        preceding_state = gen_state
    end

    return result
end
