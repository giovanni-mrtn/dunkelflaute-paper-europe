using JuMP, AxisArrays, Gurobi, UnPack, StatsPlots, Colors, Statistics, CSV, DataFrames, Plots, PrettyTables, XLSX, Dates

include("ElectricitySystemModel.jl")
include("Input.jl")
include("Helpfunctions.jl")

#//////////////////////////////////////////////////////////////////////////////////////////////////
"""
read_input(problem)

Prepare model inputs and constants.
- Builds sets: REGION, TECH, PLANT, PERIOD
- Defines the energy storage capacity (in TWh) for different types of hydropower facilities in each region
- Defines the minimum allowable energy level for hydropower reservoirs in each country
- Loads static tables (max capacities, transmission, distances)
- Defines technology parameters (costs, efficiencies, lifetimes, emissions)
- Computes derived values (CRF, transmission costs, etc.)

Arguments:
- problem: a `TModelParameters` struct with fields like `time_step`, `input_data_length`, `use_mean_aggregation`, `transmission_grid`.

Returns: a named tuple with all input arrays and parameters required by the model.
"""
function read_input(problem)
    println("\nReading Input Data...")
    @unpack time_step, input_data_length, use_mean_aggregation, transmission_grid = problem
    no_periods = div(input_data_length, time_step)
    input_dir = joinpath(@__DIR__, "..", "input")

    # Sets
    PERIOD = 1:no_periods
    REGION = [:NO, :SE, :FI, :DK, :IE, :UK, :NL, :BE, :LU, :DE, :PL, :LV, :EE, :LT, :CZ, :AT, :SK, :HU, :FR, :CH, :IT, :SI, :HR, :RO, :BG, :GR, :ES, :PT]
    TECH = [:HydroRes, :HydroRoR, :PSHopenTurb, :PSHopenPump, :PSHclosedTurb, :PSHclosedPump, :Gas, :Wind, :OffWind, :PV, :RooftopPV, :Battery, :Inverter, :Nuclear, :Electrolyzer, :H2Storage, :H2GT]
    PLANT = [:HydroRes, :HydroRoR, :Gas, :Wind, :OffWind, :PV, :RooftopPV, :Nuclear]

    # Parameters
    no_regions = length(REGION)
    no_plants = length(PLANT)
    no_techs = length(TECH)

    # Hydro reservoir energy caps [TWh] and minimum reservoir levels [fraction]
    hydro_df = CSV.read(joinpath(input_dir, "hydrotable.csv"), DataFrame)
    hydro_regions = string.(hydro_df[:, 1])
    hydro_col(name) = AxisArray([Float64(hydro_df[findfirst(==(string(r)), hydro_regions), name]) for r in REGION], REGION)
    hydroreservoir      = hydro_col(:HydroRes)
    PSopenReservoir     = hydro_col(:PSHopen)
    PSclosedReservoir   = hydro_col(:PSHclosed)
    min_reservoir_level = hydro_col(:min_level)

    # PLANT's Max Capacity [GW → MW]
    maxcap_df = CSV.read(joinpath(input_dir, "maxcaptable.csv"), DataFrame)
    maxcap_regions = string.(maxcap_df[:, 1])
    maxcap_matrix = [Float64(maxcap_df[findfirst(==(string(r)), maxcap_regions), Symbol(t)]) for r in REGION, t in TECH]
    maxcap = AxisArray(maxcap_matrix .* 1000, REGION, TECH)

    # Technology parameters
    tech_df = CSV.read(joinpath(input_dir, "techtable.csv"), DataFrame)
    tech_names = string.(tech_df.Tech)
    tech_col(colname) = AxisArray([Float64(tech_df[findfirst(==(string(t)), tech_names), colname]) for t in TECH], TECH)
    inv_cost       = tech_col(:InvCost)         # EUR/MW
    fixed_cost     = tech_col(:FixedCost)       # EUR/MW/year
    var_cost       = tech_col(:VarCost)         # EUR/MWh_elec
    fuel_cost      = tech_col(:FuelCost)        # EUR/MWh_fuel
    eta            = tech_col(:Efficiency)      # -
    lifetime       = tech_col(:Lifetime)        # years
    emissionfactor = tech_col(:EmissionFactor)  # ton/MWh

    # Transmission
    distance_df = CSV.read(joinpath(input_dir, "grid", "distance.csv"), DataFrame; header=false, skipto=2, limit=28)       # Read the CSV file into a DataFrame, skipping the header and reading only the range B2:AC29
    distance_matrix = Matrix(distance_df[:, 2:end])     # Extract columns B to AC (indices 2 to 29)
    distance = NamedArray(distance_matrix, (REGION, REGION))

    valid_links_df = CSV.read(joinpath(input_dir, "grid", "valid_links.csv"), DataFrame; header=false, skipto=2, limit=28)
    valid_links_matrix = Matrix(valid_links_df[:, 2:end])
    valid_links = NamedArray(valid_links_matrix, (REGION, REGION))

    # Reference transmission grid (upper limit)
    max_transmission_df = CSV.read(joinpath(input_dir, "grid", string(transmission_grid, "_grid.csv")), DataFrame; header=false, skipto=2, limit=28)   # e.g., "2025_grid.csv" or "2050_grid.csv"
    max_transmission_matrix = Matrix(max_transmission_df[:, 2:end])
    max_transmission = NamedArray(max_transmission_matrix, (REGION, REGION))

    loss_per_K_Km = 0.016
    discountrate = 0.05
    crf = AxisArray(discountrate ./ (1 .- 1 ./(1 + discountrate).^lifetime), TECH)
    
    transmissioncost = 400  # €/MW/km
    crf_t=discountrate ./ (1 .- 1 ./(1 + discountrate).^40)

    return (; REGION, PLANT, TECH, PERIOD, no_regions, no_plants, no_techs, no_periods,
            inv_cost, fixed_cost, var_cost, fuel_cost, eta,
            emissionfactor, crf, maxcap, hydroreservoir, PSopenReservoir, PSclosedReservoir, min_reservoir_level, transmissioncost, valid_links, distance, max_transmission, loss_per_K_Km, crf_t)
    end
#//////////////////////////////////////////////////////////////////////////////////////////////////

function safe_writetable(path::AbstractString, tables...; overwrite=true)
    try
        XLSX.writetable(path, tables...; overwrite = overwrite)
        return path
    catch err
        # File is likely locked (open in Excel/another program). Fall back to a timestamped name.
        ts = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
        base, ext = splitext(path)
        alt = base * "_" * ts * ext
        @warn "Could not write $(basename(path)) (likely open in another program). Writing to $(basename(alt)) instead." exception=err
        XLSX.writetable(alt, tables...; overwrite = overwrite)
        return alt
    end
end

"""
run_scenario_sweep(problem, input, time_series_data)

Run a single-scenario stochastic optimization for every weather year 1979:2018
and export two XLSX workbooks under `results/`:
- TCtable_<grid>grid_ts<ts>h.xlsx: one sheet with per-year total / investment / operational / fixed / demand-response costs.
- Capacities_<grid>grid_ts<ts>h.xlsx: one sheet per technology, rows = year, cols = region (GW).

Triggered when `problem.sweep_all_scenarios == true`. Ignores `problem.stochastic_model_scenarios`
and skips the per-run `SaveAllTables` HTML export.
"""

function run_scenario_sweep(problem, input, time_series_data)
    WEATHERYEARS = 1979:2018
    grid_label = problem.transmission_constrained ? problem.transmission_grid : "unconstrained"
    ts_label = string(problem.time_step)

    totalcosts_table = DataFrame(
        Year_Pair = String[], TC = Float64[], InvCost = Float64[],
        OperCost = Float64[], FixCost = Float64[], TotDemandResponseCost = Float64[]
    )

    techs_export = input.TECH
    regional_caps = Dict(t => DataFrame(Year_Pair = String[]) for t in techs_export)
    for t in techs_export
        for r in input.REGION
            regional_caps[t][!, Symbol(r)] = Float64[]
        end
    end

    results_dir = joinpath(@__DIR__, "..", "results", grid_label * "_grid")
    mkpath(results_dir)  # Create directory if it doesn't exist
    costs_path = joinpath(results_dir, "TCtable_" * grid_label * "grid_ts" * ts_label * "h.xlsx")
    caps_path  = joinpath(results_dir, "capacities_" * grid_label * "grid_ts" * ts_label * "h.xlsx")

    scenario_probability = [1.0]
    for w in WEATHERYEARS
        println("\nSolving stochastic model (year-pair: $w-$(w+1))...")
        scenario_data = ReadScenarioData([Int32(w)], scenario_probability, problem, input, time_series_data)
        sol = SolveStochasticModel(problem, input, scenario_data, time_series_data).solution

        year_label = "$(w)-$(string(w + 1)[end-1:end])"

        push!(totalcosts_table, (
            year_label,
            sol.Cost_r,                                     # TC in M€ - scalar (no index set), already /1e6 in ElectricitySystemModel.jl
            sol.InvestmentCost_r / 1e6,                     # scalar JuMP var
            sol.OperationalCost_r[1] / 1e6,                 # scenario-indexed, 1 scenario
            sol.FixedCost_r / 1e6,                          # scalar JuMP var
            sol.TotalDemandResponseCost_r[1] / 1e6
        ))

        for t in techs_export
            row = Any[year_label]
            for r in input.REGION
                push!(row, sol.Capacity_r[r, t] / 1e3)
            end
            push!(regional_caps[t], row)
        end

        # Incremental save after every solved year. 
        costs_path = safe_writetable(costs_path, totalcosts_table)
        sheets_export = [string(t) => regional_caps[t] for t in techs_export]
        caps_path = safe_writetable(caps_path, sheets_export...)
        println("Progress saved after year-pair $w-$(w+1): $(basename(costs_path)), $(basename(caps_path))")
    end

    println(totalcosts_table)
    println("Final costs table at $costs_path")
    println("Final regional capacities at $caps_path")

    return nothing
end
#//////////////////////////////////////////////////////////////////////////////////////////////////

"""
main()

Main entry point for running the model end-to-end:
1. Create a `problem` (model / scenario) parameter struct
2. Read static inputs and time-series
3. Build and solve the stochastic model (and optionally simulate results)
4. Save summary tables to an HTML file

Modify the `problem` fields above to run different experiments.
"""
function main()
    println("Starting main function...")

    scenarios = [2010]

    problem = TModelParameters(
    carbon_cap = 10/1e3,    # tonCO2/MWh (10 gCO2/kWh)
    storage = true,
    transmission = true,
    transmission_constrained = true,    # if false, the transmission grid capacities are unconstrained
    transmission_grid = "2050",     # "2025" or "2050" - valid only if transmission_constrained = true
    nuclear = true,
    input_data_length = 2*365*24,
    time_step = 7,  # hours
    demand_response_penalty = 1000,  # €/MWh %
    VOLL = 100000,  # €/MWh %
    demand_response_ratio = 0.03,
    use_mean_aggregation = false,
    fix_hydro = true,
    discharge_time = 4,   # battery energy/inverter-power ratio [h]
    planned_outage_rate = 0.15,
    stochastic_model_scenarios = scenarios,   # pair START year; e.g. 1996 means the pair 1996-1997. Valid start years: 1979..2018
    scenario_probability = fill(1.0, length(scenarios)),     # prob. will be normalized - must have same number of items as scenarios
    solve_stochastic_model = true,
    simulate_results = false,    # if true, simulate the results after solving the stochastic model
    sweep_all_scenarios = false  # if true, loop a single-scenario optimization over every year 1979:2018 and export two XLSX summaries to results/. Overrides stochastic_model_scenarios and skips SaveAllTables.
    )

    println("Problem parameters set.")
    input = read_input(problem)
    println("Input data read.")
    time_series_data = ReadTimeSeriesData(problem, input)
    println("Time series data read.")

    # Here we solve the stochastic model
    if problem.sweep_all_scenarios
        problem.simulate_results = false
        run_scenario_sweep(problem, input, time_series_data)
    elseif problem.solve_stochastic_model
        println("\nSolving stochastic model")
        stochastic_model_scenario_data = ReadScenarioData(problem.stochastic_model_scenarios, problem.scenario_probability, problem, input, time_series_data)
        stochastic_solution_results = SolveStochasticModel(problem, input, stochastic_model_scenario_data, time_series_data)

        # Automatically save results with different names
        grid_label = problem.transmission_constrained ? problem.transmission_grid : "unconstrained"
        filename = problem.simulate_results ? ("fullresults_" * join(string.(problem.stochastic_model_scenarios), "_")) : ("results_" * join(string.(problem.stochastic_model_scenarios), "_"))
        SaveAllTables(filename * "_" * grid_label * "grid", stochastic_solution_results.tables, problem.transmission_grid;      # if more details needed, replace 'filename' with 'filename * "_..."'
                      solve_time = stochastic_solution_results.solve_time,
                      simulation_time = stochastic_solution_results.simulation_time)     
    end

    return nothing
end

@time main()
