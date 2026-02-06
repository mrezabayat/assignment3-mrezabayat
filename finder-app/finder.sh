#!/bin/sh

if [ $# -ne 2 ]; then
    echo "Script expects two arguments, the first argument is a path to a directory on the filesystem;
     the second argument is a text string which will be searched within these files"
    exit 1
fi

filesdir="$1"
searchstr="$2"

if [ ! -d "$filesdir" ]; then
    echo "$filesdir is not a directory"
    exit 1
fi

number_of_files=$(find "$filesdir" -maxdepth 1 -type f | wc -l)
number_of_matching_lines=$(find "$filesdir" -maxdepth 1 -type f -exec grep "$searchstr" {} + | wc -l)

echo "The number of files are $number_of_files and the number of matching lines are $number_of_matching_lines"
