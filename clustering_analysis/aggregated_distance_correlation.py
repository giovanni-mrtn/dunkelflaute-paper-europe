"""
Hierarchical Clustering - AGGREGATED DISTANCE MATRIX Approach
(Average Linkage + Correlation distance)

Standalone script extracted from comparison_hierarchical_clustering.ipynb.
It clusters European countries by aggregating the wind and solar correlation
distance matrices (equal weights), then produces:
    1. Silhouette score plot
    2. Dendrogram
    3. Geographic cluster map (downloads Natural Earth shapefile)
"""

import os
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

import scipy.cluster.hierarchy as sch
from scipy.spatial.distance import pdist, squareform
from sklearn.metrics import silhouette_score

# ============================================================================
# 1. DATA LOADING & CONFIGURATION
# ============================================================================

df_wind  = pd.read_csv("cfwind_fullperiod.csv")
df_solar = pd.read_csv("cfsolar_fullperiod.csv")

# --- Extract specific range of years (from the end) ---
years_to_consider = 41
hours_per_year = 8760
rows_to_keep = years_to_consider * hours_per_year

df_wind  = df_wind.tail(rows_to_keep).reset_index(drop=True)
df_solar = df_solar.tail(rows_to_keep).reset_index(drop=True)

countries = [
    "NO", "SE", "FI", "DK", "IE", "UK", "NL", "BE", "LU", "DE",
    "PL", "LV", "EE", "LT", "CZ", "AT", "SK", "HU", "FR", "CH",
    "IT", "SI", "HR", "RO", "BG", "GR", "ES", "PT"
]

df_wind.columns  = countries
df_solar.columns = countries

# Range of clusters to test
min_clusters = 2
max_clusters = 14

# --- CUSTOM COLOR PALETTE FOR DENDROGRAM & MAP ---
custom_palette = [
    '#D4AC0D', '#377eb8', '#4daf4a', '#984ea3', '#e41a1c',
    '#ff7f00', '#a65628', '#f781bf', '#008080', '#17becf',
    '#8c564b', '#e377c2', '#7f7f7f', '#bcbd22', '#1f77b4'
]
sch.set_link_color_palette(custom_palette)


# ============================================================================
# 2. AGGREGATED DISTANCE MATRIX (Average Linkage + Correlation distance)
# ============================================================================

# --- Weights for aggregating wind & solar distances (normalized to sum to 1) ---
w_wind, w_solar = 1, 1
total_weight = w_wind + w_solar
w_wind_n, w_solar_n = w_wind / total_weight, w_solar / total_weight

# Determine approach name dynamically for plots / filenames
if w_wind > 0 and w_solar == 0:
    approach_name = 'Wind Correlation'
elif w_wind == 0 and w_solar > 0:
    approach_name = 'Solar Correlation'
else:
    approach_name = 'Aggregated Distance'

safe_approach_name = approach_name.replace(' ', '_').lower()


def normalize_dist(d):
    """Normalize a condensed distance vector to the [0, 1] range."""
    return (d - d.min()) / (d.max() - d.min()) if d.max() > d.min() else d


# 1. Calculate separate Correlation distance matrices
dist_wind_corr  = pdist(df_wind.T,  metric='correlation')
dist_solar_corr = pdist(df_solar.T, metric='correlation')

# 2. Normalize distance matrices (0 to 1)
dist_wind_corr_norm  = normalize_dist(dist_wind_corr)
dist_solar_corr_norm = normalize_dist(dist_solar_corr)

# 3. Weighted Aggregation
condensed_dist_agg_corr = (w_wind_n * dist_wind_corr_norm +
                           w_solar_n * dist_solar_corr_norm)

# 4. Clustering Pipeline - Hierarchical Clustering with Average linkage
linkage_matrix_agg_corr = sch.linkage(condensed_dist_agg_corr, method='average')

# --- Silhouette analysis ---
dist_matrix_agg_corr_sq = squareform(condensed_dist_agg_corr)
silhouette_scores_agg_corr = []

for k in range(min_clusters, max_clusters + 1):
    labels_temp_agg_corr = sch.fcluster(linkage_matrix_agg_corr, t=k, criterion='maxclust')
    score_agg_corr = silhouette_score(dist_matrix_agg_corr_sq, labels_temp_agg_corr, metric='precomputed')
    silhouette_scores_agg_corr.append(score_agg_corr)

# Plotting the Silhouette Scores
plt.figure(figsize=(8, 4))
plt.plot(range(min_clusters, max_clusters + 1), silhouette_scores_agg_corr, marker='o', linestyle='--')
plt.xlabel('Number of Clusters')
plt.ylabel('Silhouette Score')
#plt.title(f'{approach_name} - Average Linkage ({years_to_consider} Years)')
plt.xticks(range(min_clusters, max_clusters + 1))
plt.grid(True)
plt.savefig(f'silhouette_{safe_approach_name}_corr_{years_to_consider}years.pdf', bbox_inches='tight')
#plt.show()

# Determine optimal number of clusters based on highest silhouette score
num_clusters_agg_corr = silhouette_scores_agg_corr.index(max(silhouette_scores_agg_corr)) + min_clusters
print(f"\nOptimal k for {approach_name} (Average Linkage): {num_clusters_agg_corr}")

dynamic_threshold_agg_corr = linkage_matrix_agg_corr[-(num_clusters_agg_corr - 1), 2]

# Dendrogram
plt.figure(figsize=(7, 3))
dendro_info_agg_corr = sch.dendrogram(
    linkage_matrix_agg_corr,
    labels=countries,
    leaf_rotation=45,
    leaf_font_size=10,
    color_threshold=dynamic_threshold_agg_corr,
    above_threshold_color='grey'
)
plt.axhline(y=dynamic_threshold_agg_corr, c='grey', lw=1, linestyle='dashed')
plt.ylabel("Linkage Distance")
#plt.title(f"{approach_name} - Average Linkage (k={num_clusters_agg_corr}, {years_to_consider} Years)")
plt.tight_layout()
plt.savefig(f'dendrogram_{safe_approach_name}_corr_{years_to_consider}years.pdf', bbox_inches='tight')
#plt.show()

# Cut dendrogram to form clusters
cluster_labels_agg_corr = sch.fcluster(linkage_matrix_agg_corr, t=num_clusters_agg_corr, criterion='maxclust')

# Print Clusters
clusters_agg_corr = {i: [] for i in range(num_clusters_agg_corr)}
for country, cluster in zip(countries, cluster_labels_agg_corr):
    clusters_agg_corr[cluster - 1].append(country)

print(f"\n--- {approach_name} (Average Linkage) Clusters ({years_to_consider} Years) ---")
for cluster_id, members in clusters_agg_corr.items():
    print(f"Cluster {cluster_id + 1}: {members}")


# ============================================================================
# 3. GEOGRAPHIC CLUSTER MAP
# ============================================================================

import geopandas as gpd
import matplotlib.patheffects as pe
import matplotlib.colors as mcolors

print("Downloading 50m resolution map data...")
shapefile_url = "https://naciscdn.org/naturalearth/50m/cultural/ne_50m_admin_0_countries.zip"
world = gpd.read_file(shapefile_url)

iso_mapping = {
    'FR': 'FRA', 'CH': 'CHE', 'DE': 'DEU', 'NL': 'NLD', 'BE': 'BEL', 'LU': 'LUX',
    'IT': 'ITA', 'SI': 'SVN', 'HR': 'HRV',
    'SK': 'SVK', 'HU': 'HUN', 'PL': 'POL', 'CZ': 'CZE', 'AT': 'AUT',
    'LT': 'LTU', 'LV': 'LVA', 'EE': 'EST',
    'DK': 'DNK', 'FI': 'FIN', 'NO': 'NOR', 'SE': 'SWE',
    'GR': 'GRC', 'RO': 'ROU', 'BG': 'BGR',
    'ES': 'ESP', 'PT': 'PRT',
    'IE': 'IRL', 'UK': 'GBR'
}

# Single configuration: the Aggregated Distance (Average Linkage) approach
safe_name = f'{safe_approach_name}_average'
title = f'{approach_name} (Average Linkage)'
clusters_obj = clusters_agg_corr
dendro_obj = dendro_info_agg_corr

print(f"\nPlotting map for: {title}")

# 1. Define the clusters dynamically
cluster_dict = {str(k + 1): v for k, v in clusters_obj.items()}

# 2. Prepare the Data
data = []
for cluster_id, cluster_countries in cluster_dict.items():
    for country in cluster_countries:
        data.append({'iso_a2': country, 'Cluster': f"WZ{cluster_id}"})

df_clusters = pd.DataFrame(data)
df_clusters['iso_a3'] = df_clusters['iso_a2'].map(iso_mapping)

# 3. Merge Data
europe_map = world.merge(df_clusters, left_on='ADM0_A3', right_on='iso_a3', how='left')

# 4. Plotting Setup
fig, ax = plt.subplots(figsize=(15, 15))

# Filter Data
clustered_data = europe_map.dropna(subset=['Cluster']).copy()
clustered_data['cluster_num'] = clustered_data['Cluster'].str.replace('WZ', '').astype(int)
clustered_data = clustered_data.sort_values(by='cluster_num').drop(columns=['cluster_num'])

# --- DYNAMIC COLOR ASSIGNMENT ---
country_to_color = dict(zip(dendro_obj['ivl'], dendro_obj['leaves_color_list']))

color_mapping = {}
for cluster_id, cluster_countries in cluster_dict.items():
    first_country = cluster_countries[0]
    color_mapping[f'WZ{cluster_id}'] = country_to_color[first_country]
clustered_data['assigned_color'] = clustered_data['Cluster'].map(color_mapping)

# A. Plot Background
world.plot(ax=ax, color='#f0f0f0', edgecolor='white', linewidth=0.5)

# B. Plot Clusters
clustered_data.plot(
    color=clustered_data['assigned_color'],
    ax=ax,
    edgecolor='black',
    linewidth=0.5
)

# --- TABLE LOGIC ---
summary = clustered_data.groupby('Cluster')['iso_a2'].apply(lambda x: ', '.join(sorted(x))).reset_index()
summary.columns = ['Weather Zone', 'Countries']
summary['cluster_num'] = summary['Weather Zone'].str.replace('WZ', '').astype(int)
summary = summary.sort_values('cluster_num').drop(columns=['cluster_num'])

table_data = []
cell_colors = []

for _, row in summary.iterrows():
    wz = row['Weather Zone']
    country_str = row['Countries']
    table_data.append([wz, country_str])

    c_original = color_mapping[wz]
    c_light = mcolors.to_rgba(c_original, alpha=0.9)
    cell_colors.append([c_light, 'white'])

the_table = plt.table(
    cellText=table_data,
    colLabels=["Cluster", "Countries"],
    cellColours=cell_colors,
    loc='upper left',
    cellLoc='left',
    colWidths=[0.08, 0.18]
)

the_table.set_zorder(100)
the_table.auto_set_font_size(False)
the_table.set_fontsize(16)
the_table.scale(1.5, 1.8)

cells = the_table.get_celld()
for (row, col), cell in cells.items():
    if row == 0:
        cell.set_text_props(weight='bold')
        cell.set_facecolor('#eeeeee')
    elif row > 0:
        if col == 0:
            cell.set_text_props(ha='center')

# --- LABELS ---
special_positions = {'NO': (8.5, 61.0)}
label_nudge = {}

for idx, row in clustered_data.iterrows():
    country_code = row['iso_a2']

    if country_code in special_positions:
        x, y = special_positions[country_code]
    else:
        rep_point = row.geometry.representative_point()
        x, y = rep_point.x, rep_point.y
        if country_code in label_nudge:
            off_x, off_y = label_nudge[country_code]
            x += off_x
            y += off_y

    if -25 < x < 45 and 30 < y < 75:
        ax.annotate(
            text=country_code,
            xy=(x, y),
            horizontalalignment='center',
            verticalalignment='center',
            fontsize=16,
            fontweight='bold',
            color='black',
            path_effects=[pe.withStroke(linewidth=3, foreground="white", alpha=0.7)]
        )

# D. Final Formatting
ax.set_xlim(-18, 35)
ax.set_ylim(34, 72)
ax.set_aspect(1.5)
ax.axis('off')
#plt.title(f"{title} - {years_to_consider} Years", fontsize=20, fontweight='bold', pad=20)

# Save map dynamically named based on the approach and years considered
plt.savefig(f'WZ_{safe_name}_{years_to_consider}years_map.pdf', bbox_inches='tight')
#plt.show()
