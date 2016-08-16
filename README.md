# GTFS ready, set, go ...

**GTFS ready, set, go ...** is a bash script that download a GTFS file, and than:

-  convert it to a spatialite file;
	-  spatialize inside it the `stop` and the `route` tables;
	-  create some report tables about the GTFS data
-  export the `stop` and the `route` tables in `GeoJSON` format;
-  ... more to come.