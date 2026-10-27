# The Impacts of Spatial Representations of Dunkelflaute Events on European Electricity System Planning

Code and input data accompanying the paper:

> Giovanni Martini, Tom Schröder, Kamran Forghani, Xiaoming Kan.
> *The Impacts of Spatial Representations of Dunkelflaute Events on European Electricity System Planning.*
> Submitted, under review.

**Affiliations:** Department of Computer and Systems Sciences, Stockholm University · Department of Space, Earth and
Environment, Chalmers University of Technology · TU Berlin

## About the study

Dunkelflaute events are prolonged periods of low wind and solar output, and their timing and severity vary across
Europe. Using 41 years of historical weather data (1979–2019), organized into 40 overlapping two-year periods
("year-pairs"), the study identifies Dunkelflaute events at three spatial scales: pan-European, weather zone (groups of
countries with similar wind and solar patterns), and country. These events are built into a two-stage stochastic
capacity-expansion model of a deeply decarbonized European electricity system in 2050. Each resulting system design is
then evaluated across all 40 year-pairs, using energy not served (ENS) to measure robustness.

## Repository structure

```
.
├── clustering_analysis/          Weather-zone clustering (Supplementary Material, Section S1)
│   ├── cf_data/                  Hourly onshore wind and solar PV capacity factors, 28 countries, 1979–2019
│   ├── concatenate_cf_data.jl    Merges the yearly files into one 41-year series per technology
│   ├── aggregated_distance_correlation.py   Hierarchical clustering → 9 weather zones
│   └── plots/                    Dendrogram, silhouette scores and weather-zone map (Figures S1, S2 and Fig. 1a)
│
└── european_energy_model/        Stochastic capacity-expansion and simulation model (Julia/JuMP)
    ├── Project.toml, Manifest.toml   Julia environment
    ├── src/
    │   ├── Solve.jl              Entry point: run settings in main()
    │   ├── ElectricitySystemModel.jl   Stochastic Model and Simulation Model
    │   ├── Input.jl              Reads time series and scenario data
    │   └── Helpfunctions.jl      Result tables, export and plotting
    └── input/
        ├── cf_data/              Hourly capacity factors: onshore/offshore wind, utility/rooftop PV, 1979–2019
        ├── load/                 2050 hourly electricity demand
        ├── hydro_inflow/         Hourly inflow: reservoir, run-of-river, pumped storage
        ├── grid/                 Interconnector capacities (2025, 2050), distances, valid links
        ├── techtable.csv         Technology costs and performance
        ├── maxcaptable.csv       Capacity potentials per country and technology
        └── hydrotable.csv        Hydropower storage capacities and minimum reservoir levels
```

## Workflow

The analysis has three steps. Steps 1 and 3 are included in this repository.

### 1. Weather-zone clustering (`clustering_analysis/`)

The 28 countries are grouped into nine weather zones using hierarchical clustering (average linkage) on the correlation
distances of their wind and solar capacity factors (Supplementary Material, Section S1).

```bash
cd clustering_analysis
julia concatenate_cf_data.jl            # writes cf*_fullperiod.csv (>100 MB, not tracked) in this folder
python aggregated_distance_correlation.py   # writes the silhouette, dendrogram and map PDFs in this folder
```

Resulting weather zones:

| Zone | Countries | Zone | Countries |
|---|---|---|---|
| WZ1 | ES, PT | WZ6 | AT, CZ, HU, PL, SK |
| WZ2 | DK, NO, SE | WZ7 | IE, UK |
| WZ3 | EE, FI, LT, LV | WZ8 | BE, DE, LU, NL |
| WZ4 | BG, GR, RO | WZ9 | CH, FR |
| WZ5 | HR, IT, SI | | |

### 2. Dunkelflaute detection and drought mass (not included)

Dunkelflaute events are detected with the Variable-duration Mean-Below-Threshold (VMBT) method and ranked by drought mass,
following Kittel and Schill (paper Sections 2.2 and 2.5; Supplementary Material, Sections S2–S4). This step builds on
the VREDA tool by Kittel and Schill
([gitlab.com/diw-evu/variable_renewable_energy_droughts_analyzer](https://gitlab.com/diw-evu/variable_renewable_energy_droughts_analyzer)). Its results, the worst-case year-pair for each spatial unit, are reported in
Table 3 of the paper and are used directly as model scenarios in step 3.

### 3. Capacity expansion and robustness assessment (`european_energy_model/`)

The **Stochastic Model** optimizes generation, storage and transmission capacities across the weather scenarios of a
case. With `simulate_results = true`, the **Simulation Model** then dispatches the resulting design across all 40
year-pairs to compute ENS and operating costs (paper Section 2.3; Supplementary Material, Sections S5–S8).

```bash
cd european_energy_model
julia --project=. -e 'using Pkg; Pkg.instantiate()'   # first time only
julia --project=. src/Solve.jl
```

Run settings are set in `main()` in `src/Solve.jl`. The main options:

| Option | Meaning | Paper setting |
|---|---|---|
| `scenarios` | Start years of the year-pairs to include (e.g. `1996` = 1996–1997) | see the table below |
| `transmission_grid` | `"2050"` or `"2025"` interconnector limits | `"2050"` (main), `"2025"` (sensitivity) |
| `transmission_constrained` | `false` = no upper bound on interconnectors | `true` (main), `false` (sensitivity) |
| `time_step` | Temporal resolution in hours | `7` (main), `1` (sensitivity) |
| `simulate_results` | Evaluate the design across all 40 year-pairs | `true` |
| `sweep_all_scenarios` | Solve each year-pair deterministically (used for the capacity weights, SM S2) | `false` |

Scenarios for the five cases (worst-case year-pairs from Table 3, duplicates removed):

| Case | Description | `scenarios` |
|---|---|---|
| Benchmark | Typical year-pair for Europe | `[2010]` |
| Case 1 | Worst year-pair for Europe | `[1996]` |
| Case 2 | Worst year-pair for each weather zone (6 distinct) | `[1979, 1983, 1984, 1996, 2001, 2016]` |
| Case 3 | Worst year-pair for each country (18 distinct) | `[1979, 1982, 1983, 1984, 1987, 1988, 1993, 1995, 1996, 1997, 1998, 2000, 2001, 2007, 2008, 2009, 2012, 2015]` |
| Case 4 | All 40 year-pairs | `collect(1979:2018)` |

All scenarios in a case have equal probability (`scenario_probability = fill(1.0, length(scenarios))`). Results are
written to `european_energy_model/results/`.

## Requirements

- **Julia 1.12.6** and the packages pinned in `european_energy_model/Manifest.toml` (JuMP, Gurobi.jl, CSV, DataFrames, …).
- **Gurobi Optimizer** with a valid license. The paper used v13.0.2 with the barrier method and crossover disabled.
  Free academic licenses are available from [gurobi.com](https://www.gurobi.com).
- **Python 3** with `numpy`, `pandas`, `matplotlib`, `scipy`, `scikit-learn` and `geopandas` for the clustering.

## Input data sources

All input data are derived from openly available sources:

- **Wind and solar capacity factors:** generated from ERA5 reanalysis data (Copernicus Climate Change Service, Climate
  Data Store), following the method of Mattsson et al. (2021), *Energy Strategy Reviews* 33, 100606,
  doi:[10.1016/j.esr.2020.100606](https://doi.org/10.1016/j.esr.2020.100606).
  Contains modified Copernicus Climate Change Service information. Neither the European Commission nor ECMWF is
  responsible for any use of this information.
- **Electricity demand (2050):** ENTSO-E/ENTSOG, TYNDP 2022 Scenario Data.
- **Hydropower capacities and inflows:** ENTSO-E/ENTSOG, TYNDP 2024 Scenarios; ENTSO-E Transparency Platform.
- **Interconnector capacities:** Ember, Europe Electricity Interconnection Data Tool (2025).
- **Technology costs and performance:** Danish Energy Agency, Technology Data for Generation of Electricity and
  District Heating; Technology Data for Energy Storage (2025).

Full references are given in the paper. Third-party data remain subject to the terms of their original providers.


