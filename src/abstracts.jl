abstract type AbstractDataGenerator end
function launch end

abstract type AbstractGrid end

abstract type AbstractUncertaintyDist end

abstract type AbstractSchedule end

abstract type  AbstractRunnable end
abstract type  AbstractTSO <: AbstractRunnable  end
abstract type  AbstractMarket <: AbstractRunnable  end

abstract type DeciderType end

abstract type  AbstractContext end
function run(runnable::AbstractRunnable, context::AbstractContext) error("unimplemented") end
function update!(context::AbstractContext, result, runnable::AbstractRunnable) error("unimplemented") end
