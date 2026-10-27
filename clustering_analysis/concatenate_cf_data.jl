using CSV
using DataFrames

function merge_capacity_factors()
    input_folder = joinpath(@__DIR__, "cf_data")
    technologies = ["wind", "offwind", "solar", "roof"]
    years = 1979:2019
    
    # Process each technology one by one
    for tech in technologies
        println("Processing technology: $tech...")
        
        # Array to hold the DataFrames for the 40 years
        yearly_dfs = DataFrame[]
        
        for year in years
            filename = "cf$(tech)_$(year).csv"
            filepath = joinpath(input_folder, filename)
            
            if isfile(filepath)
                # Read the CSV file into a DataFrame
                df = CSV.read(filepath, DataFrame)
                # Drop Feb 29 (hours 1417-1440) from leap-year files
                if nrow(df) == 8784
                    delete!(df, 1417:1440)
                end
                # Append the DataFrame to the array
                push!(yearly_dfs, df)
            else
                @warn "File not found: $filepath"
            end
        end
        
        # Check if we collected any data to prevent errors
        if !isempty(yearly_dfs)
            # Vertically concatenate all 41 years of data into a single DataFrame
            merged_df = vcat(yearly_dfs...)
            
            output_filename = "cf$(tech)_fullperiod.csv"
            
            # Write the merged DataFrame to the new CSV file
            CSV.write(output_filename, merged_df)
            
            # Print a success message with the row count for verification
            println("Successfully saved $output_filename with $(nrow(merged_df)) rows and $(ncol(merged_df)) columns.\n")
        else
            println("No data found for technology $tech, skipping...\n")
        end
    end
    println("All technologies processed successfully!")
end

# Execute the function
merge_capacity_factors()
