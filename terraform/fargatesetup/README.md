#### Deploy fbctf in terraform


So you want to run your fbctf app in a fargate container and have RDS MYSQL as a backend database? You can reuse this quick & dirty terraform code i wrote. 

Because I didnt have enough time, it is not very well written and it is defintely something you want to blow away once you are done.

It may be more reliable to run it in an EC2 instance but I just wanted to play with fargate + terraform hence i built it this way.

Overall the code works like this:

 - First pick a region that you wanna build your ctf and modify the terraform code appropriately.
 - The terraform does the following:
    - Issue an Amazon certificate for the dns entry you want use to CNAME to the load balancer (ALB) of the CTF app. This process will time out after 10 minutes in which time you need to create the dns validation entry to prove the ownership of the domain.
    - Plumbing network infra (1 vpc, 2 public subnet, 2 private subnet) - I didn't bother having a Nat gateway as it adds extra money but if you want servers in private subnet communicating out to the internet, you probably need to modify the code a bit
    - Creating an mysql database for your ctf with your specified username and password in tfvars file
    - Creating the ecs fargate cluster + task definition and ecs service that would execute the task and keeps it alive.
    - Pull my modified version of fbctf from docker hub (https://hub.docker.com/r/santrancisco/sanctf) and deploy it 

Things i ignored and needed to fix in the future:
 
 - Put the health check back to task definition (curl -f -k https://localhost || exit 1). This for some reason keeps failing, possibly that i'm hitting a selfsigned cert and doesnt matter what i do it would return different error code? i'm not sure. I cant use port 80 cause by default the fbctf docker container has nginx redirect you back to 443 and curl will only return 0 if server return with a 200 OK not a 301 Redirect. Something to look at another day.
 - All ECS instances are part of a target group and load balanced using the ALB. However, they are living in public subnet with an internet IP attached to it so it can download the docker image from docker hub.

Now if you are ready for terraform, Start with creating a terraform.tfvars file base on the example with all the values you intent to use.

In the first run of the code, make sure you **modify the task definition for our ECS task in main.tf** and change the environment variable "DONT_RESET_DB" to "RESET_DB". 
This will trigger my modified version of the startup script for docker container to setup the remote database with the right schema and tables, etc

```
terraform init
terraform apply
```

Once you are done with initial terraform deploy, you can try hitting the ctf website via https://ctf.awesomedomain.com" . It should work. However, don't forget the next step!

Next, you will get rid of the environment variable above or change it back to "DONT_RESET_DB" and run `terraform apply` again. Your app will be offline for a minute or two when the new version of task definition being applied. 

This step is important because your app could die due to resource exhaustion for example and ECS service will restart your service, in which case, if the RESET_DB env variable still exists, it would reset the database and you will lose all your hard work!!!!

It is important to export the levels and the quiz as you go along and build it incase you lose the data.

Happy hacking.

San

