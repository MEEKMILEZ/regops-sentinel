\# ECS Exec Port-Forward Failed with TargetNotConnected — Brain Task Role Was Missing ssmmessages:\* Permissions



\*\*Status:\*\* Resolved

\*\*Date:\*\* 2026-05-09

\*\*Affected component:\*\* Brain ECS service (`regops-sentinel-dev-brain-1a8df723`), task role `regops-sentinel-dev-brain-task-role-1a8df723`



\## The symptom



I needed to connect DBeaver on my laptop to the RDS Postgres instance to capture screenshot 26 from the manifest. RDS lives in private subnets with no public route, so the standard pattern is SSM Session Manager port-forwarding through a running ECS task as the relay. The flow looks like this:



```

laptop:5432 → AWS SSM → ECS task (Brain container) → RDS:5432

```



I built the start-session command with the cluster name, task ID, and runtime ID, ran it, and got back:



```

aws: \[ERROR]: An error occurred (TargetNotConnected) when calling the StartSession operation:

ecs:regops-sentinel-dev-cluster-1a8df723\_b7c66ed667a146429008a909f185e6ea\_b7c66ed667a146429008a909f185e6ea-2200474099 is not connected.

```



Confusing because everything \*looked\* like ECS Exec was set up correctly:



\- `aws ecs describe-services ... --query "services\[0].enableExecuteCommand"` → `true`

\- `aws ecs describe-tasks ... --query "tasks\[0].enableExecuteCommand"` → `true`

\- The task SG egress was wide open (`-1` protocol, `0.0.0.0/0`)

\- The task was `RUNNING` and reporting healthy on the ALB



\## Tracing it



The first useful diagnostic was checking the SSM agent's lifecycle inside the container:



```powershell

aws ecs describe-tasks `

&#x20; --cluster regops-sentinel-dev-cluster-1a8df723 `

&#x20; --tasks <task-id> `

&#x20; --query "tasks\[0].containers\[0].managedAgents" `

&#x20; --profile regops-sentinel `

&#x20; --region ca-central-1

```



Output showed the `ExecuteCommandAgent` had a `lastStatus: RUNNING` for that initial broken task, which made the failure even stranger — agent claimed to be running, port-forward claimed it couldn't find a target.



The clue was in AWS's documentation buried in the ECS Exec setup guide: the agent uses the \*\*task role\*\* (not the execution role) to make outbound calls to AWS Systems Manager messaging endpoints. Without those four specific actions on the task role, the agent process can come up locally but never finish registering itself with SSM as a connectable target. From SSM's perspective, the task simply doesn't exist.



The four actions are:



\- `ssmmessages:CreateControlChannel`

\- `ssmmessages:CreateDataChannel`

\- `ssmmessages:OpenControlChannel`

\- `ssmmessages:OpenDataChannel`



Resource has to be `\*` because the SSM messages service does not support resource-level scoping — it's a documented AWS quirk, not a security smell.



My `brain\_task` role had Secrets Manager, KMS, S3, SQS, and CloudWatch Logs permissions, but no SSM messaging permissions. I had configured the service flag without granting the runtime-level capability needed to back it up.



\## The fix



Added a sixth statement to the existing inline policy on `aws\_iam\_role\_policy.brain\_task` in `terraform/environments/dev/ecs-brain-service.tf`:



```hcl

{

&#x20; Effect = "Allow"

&#x20; Action = \[

&#x20;   "ssmmessages:CreateControlChannel",

&#x20;   "ssmmessages:CreateDataChannel",

&#x20;   "ssmmessages:OpenControlChannel",

&#x20;   "ssmmessages:OpenDataChannel"

&#x20; ]

&#x20; Resource = "\*"

}

```



`terraform plan` showed exactly one change to the brain\_task policy (plus an unrelated drift fix on the RDS parameter group's `apply\_method`). `terraform apply` completed in under two seconds.



The IAM change applies to \*\*future\*\* SSM agent registrations, not the existing task. The task that failed had already exhausted its registration retries before I added the permissions. The fix needed a fresh task:



```powershell

aws ecs update-service `

&#x20; --cluster regops-sentinel-dev-cluster-1a8df723 `

&#x20; --service regops-sentinel-dev-brain-1a8df723 `

&#x20; --force-new-deployment `

&#x20; --profile regops-sentinel `

&#x20; --region ca-central-1

```



After the rolling deployment completed (\~4 minutes for Fargate), I confirmed the new task's managed agent was healthy:



```powershell

aws ecs describe-tasks `

&#x20; --cluster regops-sentinel-dev-cluster-1a8df723 `

&#x20; --tasks <new-task-id> `

&#x20; --query "tasks\[0].containers\[0].managedAgents" `

&#x20; --profile regops-sentinel `

&#x20; --region ca-central-1

```



`lastStatus: RUNNING` with a `lastStartedAt` timestamp matching the new task. The port-forward command then opened cleanly:



```

Starting session with SessionId: meek-terraform-admin-...

Port 5432 opened for sessionId meek-terraform-admin-...

Waiting for connections...

```



DBeaver connected to `localhost:5432`, ran a SELECT against the `alerts` table, and screenshot 26 was captured.



\## Why the agent reported RUNNING anyway



This is the part that almost made me look at the wrong thing. ECS reports the SSM agent's \*\*process\*\* status — whether it started inside the container — not its \*\*registration\*\* status with the SSM service. The agent process can come up, fail every retry to register because it lacks `ssmmessages:CreateControlChannel`, and still report `lastStatus: RUNNING` because the process itself is alive and looping.



The clue I missed initially: the `lastStartedAt` timestamp didn't update. A registered agent renews periodically; an unregistered agent restarts and shows the same start time forever. Worth checking next time something feels off.



\## Lessons



\- \*\*ECS Exec needs both a service-level flag and runtime-level IAM permissions on the task role.\*\* Setting `enable\_execute\_command = true` on the service gets you halfway. Without `ssmmessages:\*` on the task role, the agent runs but never registers.

\- \*\*`Resource = "\*"` is correct for `ssmmessages:\*`.\*\* AWS does not support resource-level scoping on this action class. Don't waste time trying to narrow it.

\- \*\*`managedAgents.lastStatus` reports process state, not registration state.\*\* Look at `lastStartedAt` movement to tell whether the agent is actually working with SSM.

\- \*\*Apply IAM changes, then force a new task.\*\* Existing tasks won't pick up the new permissions because the agent's registration retry budget is consumed at startup.

