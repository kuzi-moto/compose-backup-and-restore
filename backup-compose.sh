#!/bin/bash

set -e

# Verify the input arguments
if [ $# -lt 1 ]; then
  echo "Usage: $0 <stack_folder> [destination_path]"
  exit 1
fi

if [ ! -f "$1/docker-compose.yml" ]
then
  echo "ERROR: Provided directory does not contain a docker-compose.yml file."
  exit 1
fi

stack_dir="$1"
backup_dest="$2"
cwd=$(pwd)
stack_name=$(basename "$stack_dir")
backup_dir="/tmp/${stack_name}_backup"

if [ -z "$backup_dest" ]
then
  backup_dest=$(pwd)
fi

# Create backup directory
mkdir -p "$backup_dir"

# Pause the stack
cd "$stack_dir"
docker-compose pause

echo "Backing up the Docker volumes"

# get a list of all volumes that begin with the compose stack name and an underscore, excluding those with 'nfs' in their names
#volumes=$(docker volume ls | grep "^${stack_name}_" | grep -v 'nfs' | awk '{print $2}')

# loop through the volumes and archive each one
#for volume in $volumes; do
  # create a tar archive of the volume
#  docker run --rm -v "${volume}:/data" busybox tar -czf "/tmp/${volume}.tar.gz" /data
#done

docker volume ls -qf "name=${stack_name}_*" | grep -v "nfs" | while read volume; do

  echo "Backing up the volume: $volume"
  docker run --rm -v $volume:/data -v $backup_dir:/backup alpine tar -czf /backup/${volume}.tar.gz /data

done

# Tar the stack directory
tar -czf $backup_dir/${stack_name}.tar.gz .

# Unpause the stack
docker-compose unpause

# Tar the backup directory
cd /tmp
tar -czf "$backup_dest/${stack_name}_backup.tar.gz" "${stack_name}_backup"

# Remove backup directory
rm -rf "$backup_dir"

# Return to original working directory
cd "$cwd"

echo "Backup of $stack_name created at $backup_dest/${stack_name}_backup.tar.gz"
