module SciMLFisheries

using Optimization, OptimizationOptimisers, OptimizationOptimJL, ComponentArrays, Zygote, Plots, LaTeXStrings, DataFrames, Lux, Random, Statistics, Distributions, OrdinaryDiffEq, LinearAlgebra

include("helpers.jl")
include("Optimizers.jl")
include("StockAssessments.jl")
include("ModelTesting.jl")
include("SimulationModels.jl")
include("GPProductionModels.jl")
include("logisticProductionModel.jl")
include("PellaTomlinsonProductionModel.jl")
include("LSTMProductionModel.jl")
include("LogisticLSTMProductionModel.jl")


export SurplusProduction, gradient_decent!, BFGS!, plot_state_estiamtes, plot_predictions, plot_forecast, leave_future_out_cv, spEDM, spLogistic, forecast, surplus_production, mapping, fishing_mortality

end # module add