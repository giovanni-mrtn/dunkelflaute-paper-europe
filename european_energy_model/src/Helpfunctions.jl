using Printf, Crayons, PrettyTables, AxisArrays, UnPack, Plots, StatsPlots, Colors, DataFrames

#//////////////////////////////////////////////////////////////////////////////////////////////////
# Struct containing all tunable model options and scenario settings used throughout the scripts.
# Fields include solver settings and scenario choices (e.g. `stochastic_model_scenarios`, `time_step`, `transmission_grid`).
Base.@kwdef mutable struct TModelParameters
    carbon_cap :: Float32
    storage:: Bool
    transmission:: Bool
    transmission_constrained :: Bool
    transmission_grid :: String
    nuclear:: Bool
    input_data_length :: Int32
    time_step ::Int32
    stochastic_model_scenarios  :: Vector{Int32}
    scenario_probability :: Vector{Float64}
    demand_response_penalty ::Float32
    VOLL :: Float32 
    demand_response_ratio :: Float32
    use_mean_aggregation :: Bool
    planned_outage_rate ::Float32
    solve_stochastic_model :: Bool
    simulate_results :: Bool
    fix_hydro:: Bool
    discharge_time :: Float32
    sweep_all_scenarios :: Bool = false
end

#//////////////////////////////////////////////////////////////////////////////////////////////////
"""
GetTableSummary(problem, input, scenario_data, solution)

Create human-readable tables from the optimization solution. Returns:
- `tables`: array of tuples suitable for `SaveAllTables`
- `PlantGeneration`, `InstalledCapacity`, `Electricity_r`: arrays useful for plotting
"""
function GetTableSummary(problem, input, scenario_data, solution)       # Summarize model solution into tables

    @unpack storage, transmission, nuclear, time_step, demand_response_penalty, planned_outage_rate = problem 
    @unpack REGION, TECH, PERIOD, no_regions, no_techs, no_periods, valid_links = input
    @unpack Cost_r, Capacity_r, Electricity_r, TransmissionCapacity_r, TotalEmissions_r, TotalDemandResponseCost_r, OperationalCost_r, FixedCost_r, InvestmentCost_r =solution
    @unpack SCENARIO, no_scenarios, load, cf, prob = scenario_data

    TransmissionCapacity = AxisArray(zeros(no_regions, no_regions), REGION, REGION)
    no_plants = length(TECH)
    for r in REGION
        for r1 in REGION
            if r1 > r && valid_links[r, r1]
                TransmissionCapacity[r, r1] = TransmissionCapacity_r[r, r1]/1e3 # GW
            else
                TransmissionCapacity[r, r1] = 0
            end
        end
    end 
    
    PlantGeneration = AxisArray(zeros(no_scenarios, no_plants), SCENARIO, TECH)
    PlantUtilization = AxisArray(zeros(no_scenarios, no_plants), SCENARIO, TECH)

    AveragePlantGeneration = AxisArray(zeros(no_plants), TECH)
    AveragePlantUtilization = AxisArray(zeros(no_plants), TECH)

    for s in SCENARIO
        for p in TECH
            PlantGeneration[s, p] = sum(Electricity_r[s, :, p, :])/1e6
            total_capacity = sum(Capacity_r[r, p] for r in REGION)
            if total_capacity > 1e-3
                PlantUtilization[s, p] = 100 * sum(Electricity_r[s, :, p, :]) / (time_step * no_periods * total_capacity)
            else
                PlantUtilization[s, p] = 0
            end
        end
    end

    for p in TECH    
        AveragePlantGeneration[p] = sum(PlantGeneration[:, p].*prob)
        AveragePlantUtilization[p] = sum(PlantUtilization[:, p].*prob)
    end

    PlantGenerationData = vcat(PlantGeneration, AveragePlantGeneration')
    PlantUtilizationData = vcat(PlantUtilization, AveragePlantUtilization')

    PlantGenerationLabel = vcat("Scenario " .* string.(SCENARIO), "Average")

    InstalledCapacity = AxisArray(zeros(no_regions, no_techs), REGION, TECH)
    TotalInstalledCapacity = AxisArray(zeros(no_techs), TECH)
    for r in REGION
        for p in TECH
            InstalledCapacity[r, p] = Capacity_r[r, p]/1e3          
        end
    end

    for p in TECH
        TotalInstalledCapacity[p] = sum(InstalledCapacity[:, p]) 
    end

    InstalledCapacityData = vcat(InstalledCapacity, TotalInstalledCapacity');
    InstalledCapacityLabel = vcat(string.(REGION), "Total")

    
    SatisfiedLoad = AxisArray(zeros(no_scenarios), SCENARIO)
    DemandResponse = AxisArray(zeros(no_scenarios), SCENARIO)
    UnitSystemCost = AxisArray(zeros(no_scenarios), SCENARIO)
    for s in SCENARIO
        DemandResponse[s] = TotalDemandResponseCost_r[s]/demand_response_penalty
        SatisfiedLoad[s] = (sum(load[s,:,:])*time_step) - DemandResponse[s] 
        UnitSystemCost[s] = (InvestmentCost_r + OperationalCost_r[s] + FixedCost_r + TotalDemandResponseCost_r[s]) / SatisfiedLoad[s]
    end
 
    # TABLES

    # Create Model Parameters table
    # Manually define parameters and their values for the summary table
    params_list = [
        "Transmission Constrained" => problem.transmission_constrained,
        "Transmission Grid"        => problem.transmission_grid,
        "Nuclear"                  => problem.nuclear,
        "Input Data Length [h]" => problem.input_data_length,
        "Time Step [h]"            => problem.time_step,
        "Demand Response Penalty [€/MWh]" => problem.demand_response_penalty,
        "Value of Lost Load (VOLL) [€/MWh]" => problem.VOLL,
        "Demand Response Ratio"      => problem.demand_response_ratio,
        "Planned Outage Rate"     => problem.planned_outage_rate,
        "Stochastic Scenarios (Year Pairs)"     => problem.stochastic_model_scenarios,
        "Scenario Probabilities"   => problem.scenario_probability,
        "Simulation Over All Years" => problem.simulate_results
        # if more parameters needed, add: "Label" => problem.field_name
    ]

    param_names = [p[1] for p in params_list]
    param_values = [p[2] for p in params_list]

    # Convert vectors to string for display
    param_values = map(x -> x isa AbstractArray ? "[" * join(x, ", ") * "]" : x, param_values)
    model_params_data = DataFrame(Setting = param_names, Value = param_values)

    Total_costs_r = InvestmentCost_r/1e6 + sum(OperationalCost_r .* prob)/1e6 + FixedCost_r/1e6 + sum(TotalDemandResponseCost_r .* prob)/1e6
    tempdata_1_vec = [Cost_r,
                  Total_costs_r,
                  InvestmentCost_r/1e6,
                  FixedCost_r/1e6,
                  sum(OperationalCost_r .* prob)/1e6,
                  sum(TotalEmissions_r .* prob)/1e6,
                  sum(TotalDemandResponseCost_r .* prob)/1e6,
                  sum(SatisfiedLoad .* prob)/1e6,
                  sum(DemandResponse .* prob)/1e6,
                  sum(UnitSystemCost .* prob)]
    
    templabel_1 = ["Objective Function (M€)",
                    "Total Costs (M€)",
                    "Investment Cost (M€)",
                    "Fixed Cost (M€)",
                    "Operational Cost (M€)",
                    "CO2 Emissions (Mt)",
                    "Demand Response Cost (M€)",
                    "Satisfied Load (TWh)",
                    "Demand Response (TWh)",
                    "Unit System Cost (€/MWh)"]
    
    # Create the cost summary table by combining labels and values into a single DataFrame.
    # Use DataFrame to ensure robust handling by PrettyTables
    tempdata_1 = DataFrame(Row = templabel_1, Value = tempdata_1_vec)
    # FixedCost is scenario-independent so it is reported once in tempdata_1 (Cost Summary)
    # and dropped from the per-scenario breakdown below.
    tempdata_2 =  [ (prob .*100)';
                    (OperationalCost_r ./1e6)';
                    (TotalEmissions_r ./1e6)';
                    (TotalDemandResponseCost_r ./1e6)';
                    (SatisfiedLoad ./1e6)';
                    (DemandResponse ./1e6)';
                    UnitSystemCost' ]

    templabel_2 = ["Probability (%)",
                      "Operational Cost (M€)",
                      "CO2 Emissions (Mt)",
                      "Demand Response Cost (M€)",
                      "Satisfied Load (TWh)",
                      "Demand Response (TWh)",
                      "Unit System Cost (€/MWh)"]

    tables = [
        ("Model Settings:", model_params_data, ["Setting", "Value"], []),
        ("Cost Summary:", tempdata_1, ["Row", "Value"], []),
        ("Installed Capacity (GW): ", InstalledCapacityData, string.(TECH), InstalledCapacityLabel),
        ("Transmission Capacity (GW): ", TransmissionCapacity, string.(REGION), string.(REGION)),
        ("Generation (TWh): ", PlantGenerationData, string.(TECH), PlantGenerationLabel),
        ("Utilization (%): ", PlantUtilizationData, string.(TECH), PlantGenerationLabel),
        ("Scenario Summary: ", tempdata_2, "Scenario " .* string.(SCENARIO), templabel_2)
    ]  
    return (; tables, PlantGeneration, InstalledCapacity, Electricity_r)

end

#//////////////////////////////////////////////////////////////////////////////////////////////////
"""
SaveAllTables(filename, tables)

Save a list of tables (as produced by `GetTableSummary`) to an HTML file using `PrettyTables`.
- `filename` will be written to the current working directory with `.html` extension.
"""
function format_hm(seconds)
    total_min = round(Int, seconds / 60)
    h = div(total_min, 60)
    m = total_min - h * 60
    return "$(h) h $(m) min"
end

function SaveAllTables(filename, tables, transmission_grid; solve_time=nothing, simulation_time=nothing)
    try
        results_dir = joinpath(@__DIR__, "..", "results")
        mkpath(results_dir)
        out_path = joinpath(results_dir, "$filename.html")
        open(out_path, "w") do f
            # --- HTML header ---
            println(f, "<html><head><style>")
            println(f, "table {border-collapse: collapse; width: auto;}")
            println(f, "th, td {border: 1px solid #ddd; padding: 8px; text-align: left;}")
            println(f, "th {background-color: #f2f2f2; font-weight: bold;}")
            println(f, "</style></head><body>")

            for (table_name, table_data, table_headers, table_rownames) in tables
                println("$table_name")

                # Convert all tables to DataFrame for consistent handling
                if table_data isa DataFrame
                    df = table_data
                else
                    # Convert matrix/AxisArray to DataFrame
                    if isempty(table_rownames)
                        df = DataFrame(table_data, Symbol.(table_headers))
                    else
                        # Create DataFrame with row names as first column
                        df = DataFrame(table_data, Symbol.(table_headers))
                        # Use "Row" for tables starting from "Generation" onwards, otherwise "Region"
                        col_name = if occursin("Generation", table_name) || occursin("Utilization", table_name) || occursin("Scenario Summary", table_name) || occursin("Simulation Results", table_name)
                            :Row
                        else
                            :Region
                        end
                        insertcols!(df, 1, col_name => table_rownames)
                    end
                end

                # Format numeric columns to remove exponential notation
                for col in names(df)
                    if eltype(df[!, col]) <: Number
                        df[!, col] = map(x -> begin
                            rounded = round(x, digits=4)
                            # Format as string to avoid exponential notation
                            if abs(rounded) < 0.0001 && rounded != 0
                                @sprintf("%.4e", rounded)
                            else
                                rounded
                            end
                        end, df[!, col])
                    end
                end

                # Convert DataFrame to matrix to avoid showing type subheader
                headers = names(df)
                data_matrix = Matrix(df)

                # Print to console
                pretty_table(stdout, data_matrix)
                println("")  # spacing in console

                # Write to HTML file manually
                println(f, "<h3>$table_name</h3>")
                println(f, "<table>")
                println(f, "  <thead>")
                println(f, "    <tr>")
                for header in headers
                    println(f, "      <th style=\"font-weight: bold; text-align: right;\">$header</th>")
                end
                println(f, "    </tr>")
                println(f, "  </thead>")
                println(f, "  <tbody>")
                
                # Write data rows
                for i in 1:size(data_matrix, 1)
                    println(f, "    <tr>")
                    for j in 1:size(data_matrix, 2)
                        val = data_matrix[i, j]
                        println(f, "      <td style=\"text-align: right;\">$val</td>")
                    end
                    println(f, "    </tr>")
                end
                
                println(f, "  </tbody>")
                println(f, "</table>")
                println(f, "<br><br>")

                # Insert Run Time block right after the Model Settings table
                if table_name == "Model Settings:" && solve_time !== nothing
                    println(f, "<h3>Run Time:</h3>")
                    println(f, "<table>")
                    println(f, "  <tbody>")
                    println(f, "    <tr><td style=\"text-align: left;\">Optimization</td>",
                                "<td style=\"text-align: right;\">$(format_hm(solve_time))</td></tr>")
                    if simulation_time !== nothing && simulation_time > 0
                        println(f, "    <tr><td style=\"text-align: left;\">Simulation</td>",
                                    "<td style=\"text-align: right;\">$(format_hm(simulation_time))</td></tr>")
                    end
                    println(f, "  </tbody>")
                    println(f, "</table>")
                    println(f, "<br><br>")
                end
            end

            println(f, "</body></html>")
        end

        println("All tables saved to: $out_path")

    catch e
        println("Error saving tables to file: $e")
    end
end

#//////////////////////////////////////////////////////////////////////////////////////////////////
#=
function PlotSolution(solution_summary, problem, input, scenario_data)
    @unpack time_step = problem
    @unpack REGION, TECH, PERIOD, no_regions, no_techs, no_periods = input
    @unpack SCENARIO, no_scenarios, load = scenario_data
    @unpack PlantGeneration, InstalledCapacity, Electricity_r = solution_summary

    # Define a color mapping for consistency across all plots
    color_map = Dict(
        :HydroRes => :dodgerblue3,
        :HydroRoR => :deepskyblue,
        :PSHopenTurb => :seagreen3,
        :PSHopenPump => :seagreen2,
        :PSHclosedTurb => :forestgreen,
        :PSHclosedPump => :limegreen,
        :Gas => :firebrick3,
        :Wind => :skyblue,
        :OffWind => :steelblue,
        :PV => :gold,
        :RooftopPV => :orange,
        :Battery => :darkorange1,
        :Inverter => :purple,
        :H2GT => :brown,
        :Electrolyzer => :tan,
        :Nuclear => :lime
    )

    gr()

    # --- Installed capacity (stacked by technology) ---
    x_regions = string.(REGION)
    tech_colors = [get(color_map, p, :gray) for p in TECH]

    groupedbar(x_regions, Matrix(InstalledCapacity),
        title="Installed capacity (GW)",
        ylabel="GW",
        bar_position = :stack,
        bar_width = 0.5,
        color = permutedims(tech_colors),
        labels = permutedims(string.(TECH)),
        tickfont=14, legendfont=12, guidefont=12, titlefont=14,
        legend = :outertopright, size = (1000, 500), automargin=true) |> display

    # --- Plant generation by scenario (stacked) ---
    SELECTEDPLANTS = [:HydroRes, :HydroRoR, :Gas, :Wind, :OffWind, :PV, :RooftopPV, :Inverter, :Nuclear]
    no_selected_plants = length(SELECTEDPLANTS)

    gen_matrix = Array(PlantGeneration[:, SELECTEDPLANTS])  # dimensions: scenarios x selected_plants (TWh)
    scen_labels = string.(SCENARIO)
    plant_colors = [get(color_map, p, :gray) for p in SELECTEDPLANTS]

    groupedbar(scen_labels, gen_matrix,
        title="Plant generation (TWh)",
        ylabel="TWh",
        bar_position = :stack,
        bar_width = 0.5,
        color = permutedims(plant_colors),
        labels = permutedims(string.(SELECTEDPLANTS)),
        tickfont=14, legendfont=12, guidefont=12, titlefont=14,
        legend = :outertopright, size = (1000, 500), automargin=true) |> display

    # --- Time series: stacked area of selected plant generation and load ---
    PERIODSCENARIO = 1:(no_periods * no_scenarios)
    total_periods = length(PERIODSCENARIO)
    production = zeros(Float64, no_selected_plants, total_periods)  # TWh per period
    TotalElecLoad = zeros(Float64, total_periods)  # TWh per period

    for s in SCENARIO
        for h in PERIOD
            index = (s - 1) * no_periods + h
            for (i, p) in enumerate(SELECTEDPLANTS)
                production[i, index] = sum(Electricity_r[s, :, p, h]) / 1e6  # Convert MWh -> TWh
            end
            TotalElecLoad[index] = sum(load[s, REGION, h]) * time_step / 1e6  # TWh
        end
    end

    x = PERIODSCENARIO
    # Plot stacked area (use seriestype=:area with stack=true)
    areaplot(x, production', labels = permutedims(string.(SELECTEDPLANTS)), color = permutedims(plant_colors), fillalpha = 0.95,
         xlabel="Period", ylabel="TWh", title="Time series generation (stacked)", legend = :outertopright,
         tickfont=12, legendfont=12, guidefont=14, titlefont=16, size=(1500,500), automargin=true)

    # Overlay load as a line
    plot!(x, TotalElecLoad, linewidth=2.5, color=:black, linestyle=:solid, label="Load") |> display
end
=#