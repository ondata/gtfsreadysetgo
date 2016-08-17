#!/bin/bash

### requirements
# gdal >= 2.1
# spatialite
# unzip
# curl
### requirements


# A variable for the currenct directory of this script. All the output files will be created inside it
workingFolder=${PWD}

# To set the name of the principal output folder. It will be created inside the workingFolder
output="output_example_folder"

# The output name of the downloaded GTFS file
fileName="feed_gtfs"

# create two output folders
rm -rf "$workingFolder/$output" > /dev/null 2>&1
mkdir "$workingFolder/$output" > /dev/null 2>&1
mkdir "$workingFolder/temp" > /dev/null 2>&1    

# the URL of the source GTFS. It must be a zip file
URLGTFS="https://www.comune.palermo.it/gtfs/amat_feed_gtfs.zip"

# download the GTFS file
echo "Starting the GTFS download"
curl -sL "$URLGTFS" > "$workingFolder/$fileName.zip"

# unzip the GTFS file
rm "$workingFolder/$fileName"/*.csv > /dev/null 2>&1
rm "$workingFolder/$fileName"/*.txt > /dev/null 2>&1
unzip -qq -o "$workingFolder/$fileName" -d "$workingFolder/$fileName"

# The script works only with GTFS that contains the shapes.txt file. Then there is a test to verify that it exists
if test -f "$workingFolder/$fileName"/shapes.txt 
then

# create a CSV copy of the source txt GTFS files
cd "./$fileName"
for file in *.txt
do
    cp "$file" "../$output/${file%.txt}.csv"
done
cd ..


mv "$workingFolder/$output/routes.csv" "$workingFolder"/"$fileName"/routes.csv 

# create the stop GeoJSON file
rm "$workingFolder/$output/stops.geojson" > /dev/null 2>&1
ogr2ogr -f geojson -oo AUTODETECT_TYPE=YES -oo X_POSSIBLE_NAMES=stop_lon -oo Y_POSSIBLE_NAMES=stop_lat -a_srs "+proj=longlat +datum=WGS84 +no_defs" "$workingFolder/$output/stops.geojson" "$workingFolder/$output/stops.csv"

# create a spatialite file and import the stops table inside it. The imported stops table will be a spatial table
echo "Creating the spatialite file and importing the GTFS files"

ogr2ogr -f SQLite -dsco SPATIALITE=YES -nln "stops" -oo AUTODETECT_TYPE=YES -oo X_POSSIBLE_NAMES=stop_lon -oo Y_POSSIBLE_NAMES=stop_lat -a_srs "+proj=longlat +datum=WGS84 +no_defs" "$workingFolder/$output/$fileName.sqlite" "$workingFolder/$output/stops.csv"
rm "$workingFolder/$output/stops.csv"

# import all the GTFS tables in the just created spatialite file
for file in "$workingFolder/$output/"*.csv
do
    filename=$(basename "$file")
    extension="${filename##*.}"
    filename="${filename%.*}"
    ogr2ogr -update -f SQLite -nln "$filename" -oo AUTODETECT_TYPE=YES "$workingFolder/$output/$fileName.sqlite" "$workingFolder/$output/$filename.$extension"
done

ogr2ogr -update -f SQLite -nln "routes_tmp" -oo AUTODETECT_TYPE=YES "$workingFolder/$output/$fileName.sqlite" "$workingFolder/$fileName/routes.csv"

# delete all the created CSV files
rm "$workingFolder/$output/"*.csv
rm "$workingFolder/$fileName/routes.csv"

# create a file .sql useful to create the spatial routes table
echo "Making spatial the routes spatialite table"
Qrotte=${PWD}/temp/qrotte.sql

cat <<EOF > "$Qrotte"
CREATE TABLE routes AS
SELECT rt.*, CastToMultiLinestring("geometry") geometry
FROM routes_tmp rt
JOIN
(SELECT route_id,ST_Union(geometry) AS geometry
FROM
(select r.route_id, l.geometry
from 
(select shape_id, MakeLine(pt) AS geometry
    from 
    (select shape_id, CAST(shape_pt_sequence AS Integer) AS seq,
        MakePoint(CAST(shape_pt_lon AS float),CAST(shape_pt_lat AS float),4326) AS pt
        from shapes
        order by shape_id, seq) AS tpt
    group by shape_id) AS l
join 
(select distinct route_id, shape_id from trips) AS t 
on t.shape_id == l.shape_id
join 
routes_tmp AS r on r.route_id == t.route_id)
group by route_id)
using (route_id);
UPDATE geometry_columns
SET srid = 4326
WHERE f_table_name = 'routes';
UPDATE routes
SET geometry = SetSRID(geometry,4326);
SELECT RecoverGeometryColumn('routes', 'Geometry',4326, 'MULTILINESTRING', 2);
DROP TABLE routes_tmp;
EOF

# execute query using the created qrotte.sql file
spatialite "${PWD}""/$output/$fileName.sqlite" < "$Qrotte"  > /dev/null 2>&1

# export routes GeoJSON file
echo "Exporting GTFS and kml stops and routes file"
rm "${PWD}""/$output/routes.geojson" > /dev/null 2>&1
ogr2ogr -f geojson "${PWD}""/$output/routes.geojson" "${PWD}""/$output/$fileName.sqlite" routes

# export routes and stops in KML file format
ogr2ogr -f KML -dsco NameField=route_short_name -dsco DescriptionField=route_long_name "${PWD}""/$output/routes.kml" "${PWD}""/$output/$fileName.sqlite" routes
ogr2ogr -f KML -dsco NameField=stop_code -dsco DescriptionField=stop_name "${PWD}""/$output/stops.kml" "${PWD}""/$output/$fileName.sqlite" stops

# create route_type table and import it in the spatialite file
rType=${PWD}/temp/rType.csv

cat <<EOF > "$rType"
route_type,route_type_name,route_type_desc
0,"Tram, Streetcar, Light rail",Any light rail or street level system within a metropolitan area
1,"Subway, Metro",Any underground rail system within a metropolitan area
2,Rail,Used for intercity or long-distance travel
3,Bus,Used for short- and long-distance bus routes
4,Ferry,Used for short- and long-distance boat service
5,Cable car,Used for street-level cable cars where the cable runs beneath the car
6,"Gondola, Suspended cable car",Typically used for aerial cable cars where the car is suspended from the cable
7,Funicular,Any rail system designed for steep inclines

EOF

ogr2ogr -update -f SQLite -nln "route_type" -oo AUTODETECT_TYPE=YES "$workingFolder/$output/$fileName.sqlite" "$workingFolder/temp/rType.csv"

# create a sql file useful to create some GTFS report tables
echo "Creating report tables"

rSQL=${PWD}/temp/rSQL.sql

cat <<EOF > "$rSQL"
/* Number_of_modes_and_types */
CREATE table z_RoutesNumber_by_types AS 
SELECT "t"."route_type_name" AS "route_type_name", "t"."route_type_desc" AS "route_type_desc", count(*) AS routesNumber
FROM routes AS "r" 
JOIN route_type AS "t" 
ON r.route_type = t.route_type
GROUP BY t.route_type_desc;
/* Transit system in km */
CREATE table z_Transit_system_in_km AS 
SELECT "t"."route_type_name" AS "route_type_name", "t"."route_type_desc" AS "route_type_desc", 
count(*) AS routesNumber, 
SUM(GeodesicLength(r.geometry))/1000 AS lunghezzaKm
FROM routes AS "r" 
JOIN route_type AS "t" 
ON r.route_type = t.route_type
GROUP BY t.route_type_desc;
/* Number of stops by route */
Create table z_StopsNumber_by_Route AS
SELECT route_id, route_type.route_type_name type, count(*) stopsNumber
FROM
(SELECT * from
(SELECT b.*,stop_id,st.stop_sequence stop_sequence
FROM
(Select a.trip_id,a.route_id,direction_id, max(num)
FROM
(select trip_id,t.route_id, direction_id, count(*) num
from trips t
left join stop_times s using (trip_id)
group by trip_id,route_id,direction_id) a
group by route_id,direction_id) b
LEFT JOIN stop_times st using (trip_id)
order by route_id,direction_id,stop_sequence)
group by route_id,stop_id
order by route_id,direction_id,stop_sequence)
JOIN routes using (route_id)
JOIN route_type using (route_type)
GROUP by route_id;
/* Number of stops by mode*/
Create table z_StopsNumber_by_Type AS
SELECT type,sum(stopsNumber) stopsNumber
FROM
(SELECT route_id, route_type.route_type_name type, count(*) stopsNumber
FROM
(SELECT * from
(SELECT b.*,stop_id,st.stop_sequence stop_sequence
FROM
(Select a.trip_id,a.route_id,direction_id, max(num)
FROM
(select trip_id,t.route_id, direction_id, count(*) num
from trips t
left join stop_times s using (trip_id)
group by trip_id,route_id,direction_id) a
group by route_id,direction_id) b
LEFT JOIN stop_times st using (trip_id)
order by route_id,direction_id,stop_sequence)
group by route_id,stop_id
order by route_id,direction_id,stop_sequence)
JOIN routes using (route_id)
JOIN route_type using (route_type)
GROUP by route_id)
GROUP by type;
/* Ratio of route-length and number of stops */
Create table z_Stops_by_route_length AS
SELECT "route_id", "type", "stopsNumber", GeodesicLength(r.geometry) Length,
GeodesicLength(r.geometry)/stopsNumber stopsByRouteLength
FROM "z_StopsNumber_by_Route"
LEFT JOIN routes r using(route_id);
EOF

# execute the rSQL.sql query
spatialite "${PWD}""/$output/$fileName.sqlite" < "$rSQL"  > /dev/null 2>&1


### start of the reporting part ###

rReport="${PWD}/temp/rReport.sql"

cat <<EOF > "$rReport"
.output stdout
.table
EOF

# execute query using the created rReport.sql file
list=$(spatialite "${PWD}""/$output/$fileName.sqlite" < "$rReport" | grep -oP '\bz_.*?\b' | sed ':a;N;$!ba;s/\n/ /g')

mkdir "${PWD}/$output/report"
for VARIABLE in $list
do
    ogr2ogr -f CSV "${PWD}/$output/report/""$VARIABLE.csv" "${PWD}""/$output/$fileName.sqlite" "$VARIABLE"
done

### stop of the reporting part ###

# remove the temp folder and the downloaded GFTS zip file
rm -rf "$workingFolder/temp"
rm "$workingFolder/$fileName.zip"

echo "Finished"

else   
   echo "The script works only with a GTFS file that has inside the shapes.txt file"
fi

<<COMMENT1
COMMENT1