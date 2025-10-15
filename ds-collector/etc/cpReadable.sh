#!/bin/bash -e

_usage() {
cat <<EOF
  usage: $0 sourceDir targetDir

    sourceDir : must be a directory containing files to copy
    targetDir : must be an existing directory, or a valid path where a directory can be created

EOF
exit 1
}

sourceDir=$1
targetDir=$2
maxAgeDays=$3

if [ -z "${sourceDir}" -o -z "${targetDir}" ]; then
  _usage
fi

if [ ! -d ${sourceDir} -o -f ${targetDir} ]; then
  _usage
fi

if [ ! -d ${targetDir} ]; then
  mkdir -p ${targetDir}
  if [ ! -d ${targetDir} ]; then
    _usage
  fi
fi

findArgs=""
if [ "x" != "x${maxAgeDays}" ]; then
    findArgs="-mtime -${maxAgeDays}"
fi

rm -rf ${targetDir}
mkdir -p ${targetDir}
cd ${sourceDir}
for DIR in $(find . -type d | sed 's|\.||;s|/||;/^$/d'); do mkdir -p ${targetDir}/$DIR; done
for FILE in $(find . \( -type l -o -type f \) -readable ${findArgs} | sed 's|\.||;s|/||;/^$/d'); do cp -f -L $FILE ${targetDir}/$FILE; done