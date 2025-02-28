
include("ProductionModels.jl")
include("DataModels.jl")
include("Regularization.jl")
include("Priors.jl")
include("Likelihoods.jl")

function init_loss(times,dt_final,data,predict,process_loss,link,observation_loss,process_regularization,process_prior,observation_regularization,variance_prior)
    
    function loss_function(parameters)
        
        # initialize process model 
        ut = parameters.uhat[:,1]
        dt = times[2] - times[1]
        uhat, r, aux = predict(ut,dt,parameters.predict) 
        
        # calcualte loss for first observation 
        yhat = link(parameters.uhat[:,1],r,dt,parameters.link)
        L_obs = observation_loss(data[:,1], yhat,parameters.observation_loss)
        
        # initalize process loss accumulator 
        L_proc = 0 
        for t in 2:(size(data)[2])
            # calcualte forecasting error 
            ut = parameters.uhat[:,t]
            L_proc += process_loss(ut,uhat,parameters.process_loss)
            if t < size(data)[2] 
                # calcualte forecast and obervational loss using time between observations
                dt = times[t] - times[t-1]
                uhat, r, aux = predict(ut,aux,dt,parameters.predict) 
                yhat = link(ut,r,dt,parameters.link)
                L_obs += observation_loss(data[:,t], yhat,parameters.observation_loss)
            else
                # calcualte forecast and obervational loss using final value of delta t
                uhat, r, aux = predict(ut,aux,dt_final,parameters.predict) 
                yhat = link(ut,r,dt_final,parameters.link)
                L_obs += observation_loss(data[:,t], yhat,parameters.observation_loss) 
            end
        end
        
        # regularization
        L_reg = process_regularization(parameters.predict)
        L_reg += process_prior(parameters.predict)
        L_reg += observation_regularization(parameters.link)
        L_reg += variance_prior(parameters.observation_loss, parameters.process_loss)

        return L_obs + L_proc + L_reg
    end
    
end 



function init_loss_one_variances(times, data, predict, ratio, GP, k, phi, mu_log_q, sigma_log_q)
    
    function loss_function(parameters,x)
        
        # initialize process model 
        ut = parameters.uhat[:,1]
        dt = times[2] - times[1]
        uhat,sigma_2, r, aux = predict(ut,dt,parameters) 
  
        # calcualte loss for first observation 
        sigma_obs = sqrt(ratio) * parameters.GP.sigma
        sigma_proc = parameters.GP.sigma
        L = 0.5*log.(2*3.14159*sigma_obs^2) + (data[1,1] .- ut[1]).^2 ./ (2*sigma_obs^2)
        L += 0.5*log.(2*3.14159*sigma_obs^2) + (data[2,1] .- ut[2]).^2 ./ (2*sigma_obs^2)

        # initalize process loss accumulator 
        for t in 2:(size(data)[2])
            # calcualte forecasting error 
            ut = parameters.uhat[:,t]
            L += 0.5*log(2*3.14159*(sigma_2)) + (ut[1] - uhat[1])^2/(2*sigma_2) #  + nugget
            L += 0.5*log(2*3.14159*sigma_proc^2) + (ut[2] - uhat[2])^2/(2*sigma_proc^2)
            
            if t < size(data)[2] 
                # calcualte forecast and obervational loss using time between observations
                dt = times[t] - times[t-1]
                uhat, sigma_2, r, aux = predict(ut,aux,dt,parameters)    
            end
            L += 0.5*log.(2*3.14159*sigma_obs^2) + (data[1,t] .- ut[1]).^2 ./ (2*sigma_obs^2)
            L += 0.5*log.(2*3.14159*sigma_obs^2) + (data[2,t] .- ut[2]).^2 ./ (2*sigma_obs^2)
        end
     
        # gassian process priros 
        L += likelihood(parameters.GP,GP)
        L += sum(abs.(parameters.GP.l[1,1,:]).^2 ./(2*GP.psi)) # sum(0.5*log.(2*3.14159*GP.psi .^2) )+
        L += -(k-1)*log(sigma_proc^2) + sigma_proc^2/phi
        
        # parametric model priors 
        L += (parameters.log_q - mu_log_q)^2 /(2*sigma_log_q^2)

        return L
    end
    
end 


mutable struct SurplusProduction
    times
    dt_final
    data
    dataframe
    X
    parameters
    predict
    forecast_F
    forecast_H
    link
    observation_loss
    process_loss
    loss_function
    constructor
end

"""
    SurplusProduction(data;kwargs ...)

Initailizes a surplus production model to fit to the data set with a colum for time, harvest and the abundnace index. 
    
table 1: example data set 

|t  | y  |H   |
|---|----|----|
|0  | 1.0|0.1 |
|1  |0.95|0.15|
|2  |0.925|0.125|
|...|...|...|    

A number of key work arguments are used to modify the models behavior. Each of the key words specifies a specific model sturcture or model behavior, see the section on model types for details. 

```julia
SurplusProduction(data;
        # process model kwargs
        production_model = "DelayEmbedding",
        regularization_type = "L2",
        produciton_parameters = (lags=5,hidden=10,cell_dim=10,seed=1,drop_prob=0.1,extrap_value=0.1,extrap_length=0.25,regularization_weight = 10.0^-4),
        # harvest model kwargs
        harvest_model = "DiscreteAprox",
        harvest_parameters = (theta = 1.0)), 
        # Index model kwargs
        index_model="Linear",
        index_priors = (q = 0.0, b = 1.0, sigma_q = 10.0, sigma_b = 10.0),
        # process model kwargs
        likelihood="FixedVariance",
        variance_priors = (sigma_H=0.1, sigma_y = 0.1, sigma_B = 0.05, sigma_F = 0.2, sd_sigma_y=0.05,rH=0.25,sd_rH=0.025,rB=1.0,sd_rB=0.1,rF=5.0,sd_rF=0.25)
    )
```

"""
function SurplusProduction(data;
        # process model kwargs
        production_model = "DelayEmbedding",
        regularization_type = "L2",
        produciton_parameters = NamedTuple(),
        # harvest model kwargs
        harvest_model = "DiscreteAprox",
        harvest_parameters = NamedTuple(), 
        # Index model kwargs
        index_model="Identity",
        index_priors = NamedTuple(),
        # process model kwargs
        likelihood="FixedVariance",
        variance_priors = NamedTuple()
    )

    # process data
    df = deepcopy(data)
    times,data,dataframe,T = process_surplus_production_data(data)
    sd = std(dataframe.y); mu = mean(dataframe.y)
    
    # update default hyper-paramters with user inputs 
    ## proces model 
    new_produciton_parameters = ComponentArray(produciton_parameters)
    produciton_parameters = ComponentArray((n = 2.0, lags=5,hidden=10,cell_dim=10,seed=1,drop_prob=0.1,extrap_value=0.1,extrap_length=0.25,psi = 3.14159/sqrt(2), regularization_weight = 10.0^-4,prior_K = 3.0, sigma_K = 1.0, prior_r = 1.0, sigma_r = 0.1))
    produciton_parameters[keys(new_produciton_parameters)] .= new_produciton_parameters
    
    ## variance prior
    new_variance_priors = ComponentArray(variance_priors)
    variance_priors = ComponentArray((sigma_H=0.1, sigma_y = 0.1, sigma_B = 0.05, sigma_F = 0.2, sd_sigma_y=0.05,rH=0.25,sd_rH=0.025,rB=1.0,sd_rB=0.1,rF=5.0,sd_rF=0.25))
    variance_priors[keys(new_variance_priors)] .= new_variance_priors

    # harvest model 
    new_harvest_parameters = ComponentArray(harvest_parameters)
    harvest_parameters = ComponentArray((theta = 1.0))
    harvest_parameters[keys(new_harvest_parameters)] .= new_harvest_parameters

    # index model priors
    new_index_priors = ComponentArray(index_priors)
    index_priors = ComponentArray((q = 0.0, b = 1.0, sigma_q = 10.0, sigma_b = 10.0))
    index_priors[keys(new_index_priors)] .= new_index_priors

    # production model 
    predict,parameters,forecast_F,forecast_H,process_loss,loss_params = ProductionModel(production_model,data,likelihood,variance_priors.sigma_B,variance_priors.sigma_F,produciton_parameters,mu,sd)
    
    # observaiton model
    link,observation_loss,loss_params_obs,link_params=DataModel(harvest_model,index_model,likelihood,variance_priors.sigma_H,variance_priors.sigma_y,harvest_parameters.theta,sd,mu)
    
    # production regularization
    regularization_weight = produciton_parameters.regularization_weight 
    if (production_model in ["DelayEmbeddingARD", "LogisticDelayEmbedding"]) 
        regularization_weight = (L1 = regularization_weight, L2 = regularization_weight)
    elseif production_model in ["DelayEmbeddingInputScaling", "LogisticDelayEmbeddingInputScaling"]
        regularization_weight = (L2 = regularization_weight, proc_sigma =variance_priors.sigma_B)
    end

    process_regularization = Regularization(regularization_type,production_model,regularization_weight)

    # process model priors 

    process_prior = p -> 0
    if production_model == "LogisticDelayEmbeddingInputScaling"
        function process_prior(p)
            L = sum((p.K - produciton_parameters.prior_K)^2)/produciton_parameters.sigma_K^2
            L += sum((p.r - produciton_parameters.prior_r)^2)/produciton_parameters.sigma_r^2
            return L
        end
    end
    # Index model priors 
    observation_regularization = q_prior(index_priors.q,index_priors.sigma_q)
    if index_model == "HyperStability"
        observation_regularization = q_and_b_prior(index_priors.q,index_priors.b,index_priors.sigma_q,index_priors.sigma_b)
    end 
    
    # variance priors 
    variance_prior = (observation,process) -> 0.0
    if likelihood=="EstimateVariance"
        variance_prior = init_variance_prior(variance_priors.sigma_y, variance_priors.sd_sigma_y, variance_priors.rH, variance_priors.sd_rH, variance_priors.rB,variance_priors.sd_rB, variance_priors.rF, variance_priors.sd_rF)
    end 

    # loss function 
    dt_final = times[end] - times[end-1]
    loss_function = init_loss(times,dt_final,data,predict,process_loss,link,observation_loss,process_regularization,process_prior,observation_regularization,variance_prior)

    # parameters
    parameters = ComponentArray((uhat = zeros(size(data)),predict = parameters, process_loss = loss_params, link = link_params, observation_loss = loss_params_obs))

    function constructor(data;production_model = production_model,regularization_type = regularization_type,
            produciton_parameters = new_produciton_parameters, harvest_model = harvest_model,harvest_parameters = new_harvest_parameters, 
            index_model=index_model,index_priors = new_index_priors,likelihood=likelihood,variance_priors = new_variance_priors)
        
        model = SurplusProduction(data;production_model = production_model,regularization_type = regularization_type,
            produciton_parameters = produciton_parameters,harvest_model = harvest_model,harvest_parameters = harvest_parameters, 
            index_model=index_model,index_priors = index_priors,likelihood=likelihood,variance_priors = variance_priors)
        
        return model 
    end
    return SurplusProduction(times,dt_final,data,df,[],parameters,predict,forecast_F,forecast_H,link,observation_loss, process_loss,loss_function,constructor)

end 