# movies_management
## Description
Simple script for do some staff with current directory (in no parameters (except [-v]) provided) existing *.mkv files:
- checking and comparing if name of the file and "Title:" parameter in mkv metadata is the same as in IMDB;
- checking if IMBD ID is already added to global metadata of the mkv file (if not it is added by script);
- if there is already IMDB id, then cover is collected from IMDB directly;
- if there is no IMDB id, then it is trying to be collcted by API find in IMDB database, and THEN assigned;
- it is clearing all tags (I personally don't need them);
- it is removing all chapters (I'm not a fun of them either);
- it is removing all attachements (text and pictures) - due to often added inaproppriate covers;
- it is collecting covers - from IMDB
- it tries to collect subtitles for a movie
- it is changes permissions to nobody:minidlna (first for samba, and second one for minidlna)
- it is refreshing database and covers cache of minidlna service

## Prerequisites:
- account on RapidAPI (I'm using imdb-internet-movie-database-unofficial from RapidAPI) - secure key is stored in variable: ${X_RAPIDAPI_KEY}
- account in opensubtitles site and stored in variable: ${OPENSUBTITLES_PASSWORD}

## Parameters (yeah, finnaly added :))
- [-i] - providing movie file (alone only shows some details)
- [-I IMDB_ID] - providing IMDB ID (needs [-i] shows and compares some mkv details)
- [-v] - VERBOSE (more info with [-i], [-I], or without them)
- [-s] - subtitles - like with cover
- [-u] - UPDATE (needs [-i], and
  - if [-I IMDB_ID] not provided then it will try to look for IMDB ID and update it (despite it exists in file metadata)
  - if [-I IMDB_ID] provided then it will try to update IMDB ID to this one provided
  - if [-c COVER_URL] provided then cover will try to be updated - and OVERWRITEN if already exists
  - if [-s] provided then subtitles will be updated [ToDo]
  - if [-t] provided then title in metadata will be updated to file name [ToDo]

## links:
- [Movies details](https://www.imdb.com)
- [Nice poster site](https://www.joblo.com/movie-posters)
- [The Movie DB](themoviedb.org)
- [The Movie DB developers site](https://developers.themoviedb.org/4)

### some details:
For imdb there is only a "gateway" of API through RapidAPI - and... unfortunatelly it doesn't fully works as expected - but rarely
For themoviedb - they have their own API - so maybe I will also try to implement it
