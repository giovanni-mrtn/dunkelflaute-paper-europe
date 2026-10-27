using CSV, DataFrames, AxisArrays, UnPack, NamedArrays, Random, Statistics

include("Helpfunctions.jl")

# Read a yearly capacity-factor CSV. Leap-year files have 8784 hourly rows;
# drop Feb 29 (hours 1417:1440) so every file is 8760 hours and stays aligned
# with the load/inflow data (provided on a no-leap-day 8760-hour calendar).
function read_cf_csv(path::AbstractString)
    df = CSV.read(path, DataFrame)
    if nrow(df) == 8784
        deleteat!(df, 1417:1440)
    end
    return df
end

#//////////////////////////////////////////////////////////////////////////////////////////////////
"""
ReadScenarioData(selected_scenarios, scenario_probability, problem, input, time_series_data)

Map a list of selected historical year-pairs into model scenarios.
- `selected_scenarios`: vector of pair START years (e.g. [1997, 2004, 2012] means pairs 1997-1998, 2004-2005, 2012-2013). Valid start years: 1979..2017.
- `scenario_probability`: relative weights (same length)

Returns: SCENARIO index set, per-scenario `cf`, `load`, `res_inflow`, `ror_inflow`, `PS_inflow`, and `prob` (normalized probabilities).
"""
function ReadScenarioData(selected_scenarios, scenario_probability, problem, input, time_series_data)
    @unpack time_step = problem
    @unpack REGION, PERIOD, PLANT, no_regions, no_plants, no_periods = input
    @unpack simulated_cf, simulated_load, simulated_res_inflow, simulated_ror_inflow, simulated_PS_inflow = time_series_data 
    no_scenarios = length(selected_scenarios)
    SCENARIO = 1:no_scenarios
    
    load = AxisArray(zeros(no_scenarios, no_regions, no_periods), SCENARIO, REGION, PERIOD)
    res_inflow = AxisArray(zeros(no_scenarios, no_regions, no_periods), SCENARIO, REGION, PERIOD)
    ror_inflow = AxisArray(zeros(no_scenarios, no_regions, no_periods), SCENARIO, REGION, PERIOD)
    PS_inflow = AxisArray(zeros(no_scenarios, no_regions, no_periods), SCENARIO, REGION, PERIOD)
    prob = AxisArray(ones(no_scenarios)./no_scenarios, SCENARIO)
    cf = AxisArray(ones(no_scenarios, no_regions, no_plants, no_periods), SCENARIO, REGION, PLANT, PERIOD)
    
    
    SumProb=sum(scenario_probability)
    for s in SCENARIO
        prob[s] = scenario_probability[s]/SumProb
        index = selected_scenarios[s] - 1979 + 1
        cf[s, :, :Wind, :] = simulated_cf[index , :, :Wind, :]
        cf[s, :, :OffWind, :] = simulated_cf[index , :, :OffWind, :]
        cf[s, :, :PV, :] = simulated_cf[index, :, :PV, :]
        cf[s, :, :RooftopPV, :] = simulated_cf[index, :, :RooftopPV, :]
        load[s, :, :] = simulated_load[index, :, :]
        res_inflow[s, :, :] = simulated_res_inflow[index, :, :] 
        ror_inflow[s, :, :] = simulated_ror_inflow[index, :, :]
        PS_inflow[s, :, :] = simulated_PS_inflow[index, :, :]
    end

    return(; SCENARIO, no_scenarios, cf, load, res_inflow, ror_inflow, PS_inflow, prob)
end

#//////////////////////////////////////////////////////////////////////////////////////////////////
"""
prepare_simulation_data(problem, input, time_series_data, weather_selected_index)

Extract two-year (year-pair) time series for deterministic simulation runs.
Returns `cf`, `load`, and inflows for the chosen `weather_selected_index` (index into SIMULATION_YEARS; the pair starts at year `weather_selected_index + 1978`).

Used only when `problem.simulate_results = true`.
"""
function prepare_simulation_data(problem, input, time_series_data, weather_selected_index)
    @unpack time_step = problem
    @unpack REGION, PERIOD, PLANT, no_regions, no_plants, no_periods = input
    @unpack simulated_cf, simulated_load, simulated_res_inflow, simulated_ror_inflow, simulated_PS_inflow = time_series_data
  
    load = AxisArray(zeros(no_regions, no_periods), REGION, PERIOD)
    res_inflow = AxisArray(zeros(no_regions, no_periods), REGION, PERIOD)
    ror_inflow = AxisArray(zeros(no_regions, no_periods), REGION, PERIOD)
    PS_inflow = AxisArray(zeros(no_regions, no_periods), REGION, PERIOD)
    cf = AxisArray(ones(no_regions, no_plants, no_periods), REGION, PLANT, PERIOD)
    
    cf[:, :Wind, :] = simulated_cf[weather_selected_index , :, :Wind, :]
    cf[:, :OffWind, :] = simulated_cf[weather_selected_index , :, :OffWind, :]
    cf[:, :PV, :] = simulated_cf[weather_selected_index, :, :PV, :]
    cf[:, :RooftopPV, :] = simulated_cf[weather_selected_index, :, :RooftopPV, :]
    load[:, :] = simulated_load[weather_selected_index, :, :]
    res_inflow[:, :] = simulated_res_inflow[weather_selected_index, :, :] 
    ror_inflow[:, :] = simulated_ror_inflow[weather_selected_index, :, :]
    PS_inflow[:, :] = simulated_PS_inflow[weather_selected_index, :, :] 

    return(; cf, load, res_inflow, ror_inflow, PS_inflow)
end

#//////////////////////////////////////////////////////////////////////////////////////////////////

"""
ReadTimeSeriesData(problem, input)

Read all time series files used by the model over a 2-year horizon (year-pairs):
- load and hydro inflows are fixed pairs: load = WY2008+WY2009 (concatenated); hydro inflows = 2015+2016 (concatenated).
- VRE capacity-factor files vary with the pair: for each pair start year `y+1978`, the files for years `y+1978` and `y+1979` are concatenated.
Returns: SIMULATION_YEARS (1:40, mapping start years 1979..2018) and arrays `simulated_cf`, `simulated_load`, `simulated_res_inflow`, `simulated_ror_inflow`, `simulated_PS_inflow`.
Note: pair start year = y + 1978; pair end year = y + 1979.
"""
function ReadTimeSeriesData(problem, input)
    @unpack REGION, PERIOD, PLANT, no_regions, no_periods, no_plants = input
    @unpack input_data_length, time_step, use_mean_aggregation = problem
    println("\nReading time series Data...")
    input_dir = joinpath(@__DIR__, "..", "input")
    SIMULATION_YEARS = 1:40   # corresponds to pair start years 1979-2018 (pairs end at 1980..2019)
    no_simulations=length(SIMULATION_YEARS)

    load_WY2008 = CSV.read(joinpath(input_dir, "load", "load_2050_DE_WY2008.csv"), DataFrame)
    load_WY2009 = CSV.read(joinpath(input_dir, "load", "load_2050_DE_WY2009.csv"), DataFrame)
    # Last row of each file is corrupted for most countries — carry forward the previous hour.
    load_WY2008[end, :] = load_WY2008[end-1, :]
    load_WY2009[end, :] = load_WY2009[end-1, :]
    load_timeseries = vcat(load_WY2008, load_WY2009)
    res_inflow_timeseries = vcat(
        CSV.read(joinpath(input_dir, "hydro_inflow", "Res_inflow_2015.csv"), DataFrame),
        CSV.read(joinpath(input_dir, "hydro_inflow", "Res_inflow_2016.csv"), DataFrame),
    )
    ror_inflow_timeseries = vcat(
        CSV.read(joinpath(input_dir, "hydro_inflow", "RoR_inflow_2015.csv"), DataFrame),
        CSV.read(joinpath(input_dir, "hydro_inflow", "RoR_inflow_2016.csv"), DataFrame),
    )
    PS_inflow_timeseries = vcat(
        CSV.read(joinpath(input_dir, "hydro_inflow", "PS_inflow_2015.csv"), DataFrame),
        CSV.read(joinpath(input_dir, "hydro_inflow", "PS_inflow_2016.csv"), DataFrame),
    )

    simulated_load = AxisArray(zeros(no_simulations, no_regions, no_periods), SIMULATION_YEARS, REGION, PERIOD)
    simulated_res_inflow = AxisArray(zeros(no_simulations, no_regions, no_periods), SIMULATION_YEARS, REGION, PERIOD)
    simulated_ror_inflow = AxisArray(zeros(no_simulations, no_regions, no_periods), SIMULATION_YEARS, REGION, PERIOD)
    simulated_PS_inflow = AxisArray(zeros(no_simulations, no_regions, no_periods), SIMULATION_YEARS, REGION, PERIOD)
    simulated_cf = AxisArray(ones(no_simulations, no_regions, no_plants, no_periods), SIMULATION_YEARS, REGION, PLANT, PERIOD)

    for y in SIMULATION_YEARS
        # read_cf_csv() drops Feb 29 from leap-year files so every CF series
        # is 8760 hours and aligned with the load/inflow calendar.
        windtimeseries = vcat(
            read_cf_csv(joinpath(input_dir, "cf_data", "cfwind_$(y+1978).csv")),
            read_cf_csv(joinpath(input_dir, "cf_data", "cfwind_$(y+1979).csv")),
        )
        offwindtimeseries = vcat(
            read_cf_csv(joinpath(input_dir, "cf_data", "cfoffwind_$(y+1978).csv")),
            read_cf_csv(joinpath(input_dir, "cf_data", "cfoffwind_$(y+1979).csv")),
        )
        solartimeseries = vcat(
            read_cf_csv(joinpath(input_dir, "cf_data", "cfsolar_$(y+1978).csv")),
            read_cf_csv(joinpath(input_dir, "cf_data", "cfsolar_$(y+1979).csv")),
        )
        rooftopPVtimeseries = vcat(
            read_cf_csv(joinpath(input_dir, "cf_data", "cfroof_$(y+1978).csv")),
            read_cf_csv(joinpath(input_dir, "cf_data", "cfroof_$(y+1979).csv")),
        )

        if use_mean_aggregation # calculates the mean values over the time step 
            for h in PERIOD
            index = (h - 1) * time_step + 1 
            selected_range = index:index + time_step - 1
            for r in REGION
                simulated_res_inflow[y, r, h] = sum(res_inflow_timeseries[selected_range, "HydroRes_inflow_" * string(r)])/ time_step  # [MWh]
                simulated_ror_inflow[y, r, h] = sum(ror_inflow_timeseries[selected_range, "HydroRoR_inflow_" * string(r)])/ time_step
                simulated_PS_inflow[y, r, h] = sum(PS_inflow_timeseries[selected_range, "HydroPS_inflow_" * string(r)])/ time_step
                simulated_load[y, r, h] = sum(load_timeseries[selected_range, "Load_" * string(r)])/ time_step  # [MWh]

                simulated_cf[y, r,:Wind, h] = sum(windtimeseries[selected_range, string(r)])/ time_step  # 0-1, share of installed cap
                simulated_cf[y, r,:OffWind, h] = sum(offwindtimeseries[selected_range, string(r)])/ time_step
                simulated_cf[y, r,:PV, h] = sum(solartimeseries[selected_range, string(r)])/ time_step
                simulated_cf[y, r,:RooftopPV, h] = sum(rooftopPVtimeseries[selected_range, string(r)])/ time_step
            end
        end
        else # uses the values at the specific time step
            for h in PERIOD
                index = (h - 1) * time_step + 1 
                for r in REGION
                    simulated_res_inflow[y, r, h] = res_inflow_timeseries[index, "HydroRes_inflow_" * string(r)]  # [MWh]
                    simulated_ror_inflow[y, r, h] = ror_inflow_timeseries[index, "HydroRoR_inflow_" * string(r)]
                    simulated_PS_inflow[y, r, h] = PS_inflow_timeseries[index, "HydroPS_inflow_" * string(r)]
                    simulated_load[y, r, h] = load_timeseries[index, "Load_" * string(r)]  # [MWh]

                    simulated_cf[y, r,:Wind, h] = windtimeseries[index, string(r)]
                    simulated_cf[y, r,:OffWind, h] = offwindtimeseries[index, string(r)]
                    simulated_cf[y, r,:PV, h] = solartimeseries[index, string(r)]
                    simulated_cf[y, r,:RooftopPV, h] = rooftopPVtimeseries[index, string(r)]
                end
            end
        end
    end

    return(; SIMULATION_YEARS, simulated_cf, simulated_load, simulated_res_inflow, simulated_ror_inflow, simulated_PS_inflow)
end
