#### Deploy fbctf in terraform - the lazy way

This repository contains the lazy way to deploy fbctf to AWS with MYSQL RDS backend. 

It's a slightly simple hax to decouple MySQL server and keep all other components in the same EC2 instance. The fargate deployment will decouple every components into Fargate containers and RDS to make it scalable.

