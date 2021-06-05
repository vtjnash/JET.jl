# global cache
# ============

# XXX `JET_REPORT_CACHE` isn't synced with `JET_CODE_CACHE`, and this may lead to a problem ?

"""
    JET_REPORT_CACHE::$(typeof(JET_REPORT_CACHE))

Keeps JET report cache for a `MethodInstance`.
Reports are cached when `AbstractAnalyzer` exits from `_typeinf`.
"""
const JET_REPORT_CACHE = IdDict{UInt, IdDict{MethodInstance,Vector{InferenceErrorReportCache}}}()

"""
    JET_CODE_CACHE::$(typeof(JET_CODE_CACHE))

Keeps `CodeInstance` cache associated with `mi::MethodInstace` that represent the result of
  an inference on `mi` performed by `AbstractAnalyzer`.
This cache is completely separated from the `NativeInterpreter`'s global cache, so that
  JET analysis never interacts with actual code execution.
"""
const JET_CODE_CACHE = IdDict{UInt, IdDict{MethodInstance,CodeInstance}}()

# just used for interactive developments
__clear_caches!() = (empty!(JET_REPORT_CACHE); empty!(JET_CODE_CACHE))

function CC.code_cache(analyzer::AbstractAnalyzer)
    cache  = JETGlobalCache(analyzer)
    worlds = WorldRange(get_world_counter(analyzer))
    return WorldView(cache, worlds)
end

struct JETGlobalCache
    analyzer::AbstractAnalyzer
end

# cache existence for this `analyzer` is ensured on its construction
jet_report_cache(analyzer::AbstractAnalyzer)     = JET_REPORT_CACHE[get_cache_key(analyzer)]
jet_report_cache(wvc::WorldView{JETGlobalCache}) = jet_report_cache(wvc.cache.analyzer)
jet_code_cache(analyzer::AbstractAnalyzer)       = JET_CODE_CACHE[get_cache_key(analyzer)]
jet_code_cache(wvc::WorldView{JETGlobalCache})   = jet_code_cache(wvc.cache.analyzer)

CC.haskey(wvc::WorldView{JETGlobalCache}, mi::MethodInstance) = haskey(jet_code_cache(wvc), mi)

function CC.get(wvc::WorldView{JETGlobalCache}, mi::MethodInstance, default)
    # ignore code cache for a `MethodInstance` that is not yet analyzed by JET;
    ret = get(jet_code_cache(wvc), mi, default)
    if isa(ret, CodeInstance)
        # cache hit, now we need to append cached reports associated with this `MethodInstance`
        global_cache = get(jet_report_cache(wvc), mi, nothing)
        if isa(global_cache, Vector{InferenceErrorReportCache})
            analyzer = wvc.cache.analyzer
            for cached in global_cache
                restored = restore_cached_report!(cached, analyzer)
                push!(get_to_be_updated(analyzer), restored) # should be updated in `abstract_call` (after exiting `typeinf_edge`)
                # # TODO make this hold
                # @assert first(cached.vst).linfo === mi "invalid global restoring"
            end
        end
    end
    return ret
end

function CC.getindex(wvc::WorldView{JETGlobalCache}, mi::MethodInstance)
    r = CC.get(wvc, mi, nothing)
    r === nothing && throw(KeyError(mi))
    return r::CodeInstance
end

function CC.setindex!(wvc::WorldView{JETGlobalCache}, ci::CodeInstance, mi::MethodInstance)
    setindex!(jet_code_cache(wvc), ci, mi)
    add_jet_callback!(mi) # register the callback on invalidation
    return nothing
end

function add_jet_callback!(linfo)
    @static BACKEDGE_CALLBACK_ENABLED || return nothing

    if !isdefined(linfo, :callbacks)
        linfo.callbacks = Any[invalidate_jet_cache!]
    else
        if !any(@nospecialize(cb)->cb===invalidate_jet_cache!, linfo.callbacks)
            push!(linfo.callbacks, invalidate_jet_cache!)
        end
    end
    return nothing
end

function invalidate_jet_cache!(replaced, max_world, depth = 0)
    for cache in values(JET_REPORT_CACHE); delete!(cache, replaced); end
    for cache in values(JET_CODE_CACHE); delete!(cache, replaced); end

    if isdefined(replaced, :backedges)
        for mi in replaced.backedges
            mi = mi::MethodInstance
            if !(any(cache->haskey(cache, mi), values(JET_REPORT_CACHE)) ||
                 any(cache->haskey(cache, mi), values(JET_CODE_CACHE)))
                continue # otherwise fall into infinite loop
            end
            invalidate_jet_cache!(mi, max_world, depth+1)
        end
    end
    return nothing
end

# local cache
# ===========

struct JETLocalCache
    analyzer::AbstractAnalyzer
    cache::Vector{InferenceResult}
end

CC.get_inference_cache(analyzer::AbstractAnalyzer) = JETLocalCache(analyzer, get_inference_cache(get_native(analyzer)))

function CC.cache_lookup(linfo::MethodInstance, given_argtypes::Vector{Any}, cache::JETLocalCache)
    inf_result = cache_lookup(linfo, given_argtypes, cache.cache)

    isa(inf_result, InferenceResult) || return nothing

    # constant prop' hits a cycle (recur into same non-constant analysis), we just bail out
    isa(inf_result.result, InferenceState) && return inf_result

    # cache hit, try to restore local report caches
    analyzer = cache.analyzer
    sv = get_current_frame(analyzer)::InferenceState

    analysis_result = jet_cache_lookup(linfo, given_argtypes, get_cache(analyzer))

    # corresponds to report throw away logic in `_typeinf(analyzer::AbstractAnalyzer, frame::InferenceState)`
    filter!(!is_from_same_frame(sv.linfo, linfo), get_reports(analyzer))

    if isa(analysis_result, AnalysisResult)
        for cached in analysis_result.cache
            restored = restore_cached_report!(cached, analyzer)
            push!(get_to_be_updated(analyzer), restored) # should be updated in `abstract_call_method_with_const_args`
            # # TODO make this hold
            # @assert first(cached.vst).linfo === linfo "invalid local restoring"
        end
    end

    return inf_result
end

# should sync with the implementation of `cache_lookup(linfo::MethodInstance, given_argtypes::Vector{Any}, cache::Vector{InferenceResult})`
function jet_cache_lookup(linfo::MethodInstance, given_argtypes::Vector{Any}, cache::Vector{AnalysisResult})
    method = linfo.def::Method
    nargs::Int = method.nargs
    method.isva && (nargs -= 1)
    length(given_argtypes) >= nargs || return nothing
    for cached_result in cache
        cached_result.linfo === linfo || continue
        cache_match = true
        cache_argtypes = cached_result.argtypes
        cache_overridden_by_const = cached_result.overridden_by_const
        for i in 1:nargs
            if !is_argtype_match(given_argtypes[i],
                                 cache_argtypes[i],
                                 CC.getindex(cache_overridden_by_const, i))
                cache_match = false
                break
            end
        end
        if method.isva && cache_match
            cache_match = is_argtype_match(tuple_tfunc(given_argtypes[(nargs + 1):end]),
                                           cache_argtypes[end],
                                           CC.getindex(cache_overridden_by_const, CC.length(cache_overridden_by_const)))
        end
        cache_match || continue
        return cached_result
    end
    return nothing
end

CC.push!(cache::JETLocalCache, inf_result::InferenceResult) = CC.push!(cache.cache, inf_result)
