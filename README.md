# movies_management
Simple script for do some staff with current directory existing *.mkv files:
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

Prerequisites:
- account on RapidAPI (I'm using imdb-internet-movie-database-unofficial from RapidAPI) - secure key is stored in variable: ${X_RAPIDAPI_KEY}
- account in opensubtitles site and stored in variable: ${OPENSUBTITLES_PASSWORD}

Some things might not work, like titles in which there is an extra dot (curl is failing), or exclemation mark "!"... 
