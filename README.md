# wordpress litestream docker container

## Summary

This repo builds a container to host a wordpress CMS. The workpress installation is backed onto a sqlite DB 
which is replicated to S3 using [lightstream](https://litestream.io/)

## Startup

To start the container pass in AWS credentials:

```bash
docker run -it -p 8008:8008 \
  -e REPLICA_URL=s3://wordpress-cms-backup/cms-db \
  -e LITESTREAM_ACCESS_KEY_ID=$MY_AWS_ACCESS_KEY \
  -e LITESTREAM_SECRET_ACCESS_KEY=$MY_AWS_SECRET_KEY \
  docker.io/nixm0nk3y/wordpress-liststream:latest
```

