#!/bin/bash

### requisiti
# gdal >= 2.1
# spatialite
# unzip
# curl
### requisiti


cartellaLavoro=${PWD}
nomeFile="feed_gtfs"

mkdir "$cartellaLavoro/output" > /dev/null 2>&1
mkdir "$cartellaLavoro/temp" > /dev/null 2>&1

URLGTFS="https://transitfeeds-data.s3-us-west-1.amazonaws.com/public/feeds/ferrotramviaria/412/20160718/gtfs.zip"

# scarico il file GTFS
curl -sL "$URLGTFS" > "$cartellaLavoro/$nomeFile.zip"

# decomprimo il file GTFS
rm "$cartellaLavoro/$nomeFile"/*.csv
unzip -qq -o "$cartellaLavoro/$nomeFile" -d "$cartellaLavoro/$nomeFile"

# creo la copia dei file in formato CSV
cd "./$nomeFile"
for file in *.txt
do
	cp "$file" "../output/${file%.txt}.csv"
done
cd ..

mv "$cartellaLavoro"/output/routes.csv "$cartellaLavoro"/"$nomeFile"/routes.csv 

# creo il geojson delle rotte
rm "$cartellaLavoro/output/shapes.geojson"
ogr2ogr -f geojson -dialect SQLite -sql "SELECT shape_id, MakeLine(MakePoint(CAST(shape_pt_lon AS float),CAST(shape_pt_lat AS float))) FROM shapes GROUP BY shape_id" -oo AUTODETECT_TYPE=YES -a_srs "+proj=longlat +datum=WGS84 +no_defs" "$cartellaLavoro/output/shapes.geojson" "$cartellaLavoro/output/shapes.csv"

# creo il geojson delle fermate
rm "$cartellaLavoro/output/stops.geojson"
ogr2ogr -f geojson -oo AUTODETECT_TYPE=YES -oo X_POSSIBLE_NAMES=stop_lon -oo Y_POSSIBLE_NAMES=stop_lat -a_srs "+proj=longlat +datum=WGS84 +no_defs" "$cartellaLavoro/output/stops.geojson" "$cartellaLavoro/output/stops.csv"

# creo un file spatialite e importo le fermate - stops.csv - spazializzandole
ogr2ogr -f SQLite -dsco SPATIALITE=YES -nln "stops" -oo AUTODETECT_TYPE=YES -oo X_POSSIBLE_NAMES=stop_lon -oo Y_POSSIBLE_NAMES=stop_lat -a_srs "+proj=longlat +datum=WGS84 +no_defs" "$cartellaLavoro/output/$nomeFile.sqlite" "$cartellaLavoro/output/stops.csv"
rm "$cartellaLavoro"/output/stops.csv

# importo tutte le tabelle csv della cartella output nel file spatialite creato 
for file in "$cartellaLavoro"/output/*.csv
do
	filename=$(basename "$file")
	extension="${filename##*.}"
	filename="${filename%.*}"
	ogr2ogr -update -f SQLite -nln "$filename" -oo AUTODETECT_TYPE=YES "$cartellaLavoro/output/$nomeFile.sqlite" "$cartellaLavoro/output/$filename.$extension"
done

ogr2ogr -update -f SQLite -nln "routes_tmp" -oo AUTODETECT_TYPE=YES "$cartellaLavoro/output/$nomeFile.sqlite" "$cartellaLavoro/$nomeFile/routes.csv"

# cancello i file CSV temporanei creati
rm "$cartellaLavoro"/output/*.csv
rm "$cartellaLavoro/$nomeFile/routes.csv"

# creo una variabile con il puntamento a una query SQL
Qrotte=${PWD}/temp/qrotte.sql

# Creo un file e lo riempo con la query che spazializza la tabella rotte
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

# eseguo la query
spatialite "${PWD}""/output/$nomeFile.sqlite" < "$Qrotte"

# creo la tabella route_type

rType=${PWD}/temp/rType.csv

# Contenuto di route_type
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

ogr2ogr -update -f SQLite -nln "route_type" -oo AUTODETECT_TYPE=YES "$cartellaLavoro/output/$nomeFile.sqlite" "$cartellaLavoro/temp/rType.csv"

rSQL=${PWD}/temp/rSQL.csv

# query per creazione del report
cat <<EOF > "$rSQL"
/* Number_of_modes_and_types */
CREATE table z_RoutesNumber_by_types AS	
SELECT "t"."route_type_name" AS "route_type_name", "t"."route_type_desc" AS "route_type_desc", count(*) AS numeroLinee
FROM routes AS "r" 
JOIN route_type AS "t" 
ON r.route_type = t.route_type
GROUP BY t.route_type_desc;
/* Transit system in km */
CREATE table z_Transit_system_in_km AS 
SELECT "t"."route_type_name" AS "route_type_name", "t"."route_type_desc" AS "route_type_desc", 
count(*) AS numeroLinee, 
SUM(GeodesicLength(r.geometry))/1000 AS lunghezzaKm
FROM routes AS "r" 
JOIN route_type AS "t" 
ON r.route_type = t.route_type
GROUP BY t.route_type_desc;
/* Numero di fermate per rotta */
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
/* Numero di fermate per tipo */
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

spatialite "${PWD}""/output/$nomeFile.sqlite" < "$rSQL"

# cancello la cartella temporanea
rm -rf "$cartellaLavoro/temp"

