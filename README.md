# GTFS ready, set, go ...

**GTFS ready, set, go ...** is a bash script that download a GTFS file, and than:

-  convert it to a spatialite file;
	-  spatialize inside it the `stop` and the `route` tables;
	-  create some report tables about the GTFS data
-  export the `stop` and the `route` tables in `GeoJSON` format;
-  create a small report about the downloaded GTFS in HTML and Markdown format (it's still minimal and *under construction*) 
-  ... more to come.

## Requirements

- GDAL - Geospatial Data Abstraction Library >= 2.1 | http://www.gdal.org/
- spatialite | https://www.gaia-gis.it/fossil/spatialite-tools/index
- unzip
- curl
- csvtk | https://github.com/shenwei356/csvtk
- pandoc | http://pandoc.org/

## Repo folders

Inside this repo there are these two folders:

### feed_gtfs

The **GTFS ready, set, go ...** bash script will download the original zip GTFS file and will extract the GTFS txt file in this folder.

The files you find now here are only an **output example**. When you will run the script on your PC, you will find inside it the `txt` files of your GTFS.

### output_example_folder

The **GTFS ready, set, go ...** bash script will create some useful output files:

- a spatialite file with all the tables of the original GTFS file;
- the GeoJSON files for `routes` and `stops`.

The files you find now here are only an **output example**. When you will run the script on your PC, you will find inside it the output files related to your GTFS.