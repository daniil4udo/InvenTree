#!/bin/bash

docker compose down --remove-orphans
docker compose run --rm inventree-server invoke update
docker compose up -d