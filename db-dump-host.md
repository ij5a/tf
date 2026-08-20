# DB dump host

Temporary EC2 box for dumping a table and handing the file to someone else. SSM Session Manager only, no SSH and no key pair.

Turn it on per env with `enable_db_dump_host = true` and set `db_dump_host_config` in that env's tfvars. Turn it off and everything is destroyed, bucket contents included.

The host runs on a schedule (default 16:00 to 00:00 PHT). Outside the window it is stopped. Start a long dump early enough to finish, or it gets cut off.

## 1. Get the details

Replace `<env>` with the environment, for example `acme-prod`:

```bash
./scripts/<env>.sh output -raw db_dump_host_instance_id
./scripts/<env>.sh output -raw db_dump_host_bucket_name
```

The AWS profile and region for the env are in `aws-profiles.json` and its tfvars.

## 2. Start it if it is outside the window

```bash
aws ec2 start-instances --instance-ids <instance-id> --profile <profile> --region <region>
aws ec2 wait instance-running --instance-ids <instance-id> --profile <profile> --region <region>
```

Allow another minute for the SSM agent to register.

## 3. Connect

```bash
aws ssm start-session --target <instance-id> --profile <profile> --region <region>
```

You land as `ssm-user`. The bucket and DB host are already set:

```bash
source /etc/profile.d/db-dump.sh
echo $DUMP_BUCKET $DB_HOST
```

`DB_HOST` is the reader endpoint, so the dump does not touch the writer.

## 4. Dump

Everything happens on the host. Nothing needs downloading to a laptop.

```bash
mkdir -p ~/dump

mysqlsh <dbuser>@$DB_HOST -e \
  'util.dumpTables("<schema>", ["<table>"], "/home/ssm-user/dump/out", {threads: 8, consistent: false})'
```

`consistent: false` is only correct while nothing is writing to the source. Check first.

Check free space with `df -h /` before starting.

## 5. Package and hand over

```bash
tar cf ~/dump/out.tar -C ~/dump out
gpg2 --symmetric --cipher-algo AES256 -o ~/dump/out.tar.gpg ~/dump/out.tar

aws s3 cp ~/dump/out.tar.gpg s3://$DUMP_BUCKET/
aws s3 presign s3://$DUMP_BUCKET/out.tar.gpg --expires-in 21600 --region <region>
```

Or upload straight from the host to the other side, skipping S3.

Two rules for the link:

- It dies when the signing credentials expire, about 6 hours from the host whatever `--expires-in` says. Generate it right before sending.
- Send the link and the passphrase over different channels.

## 6. Afterwards

Once the other side confirms the restore, set `enable_db_dump_host = false`. That deletes the host, the bucket and anything still in it. Do not do it before the download is confirmed.

## If something breaks

- Session will not open: the host is stopped. See step 2.
- `mysqlsh: command not found`: first-boot install failed. Check `sudo tail -50 /var/log/cloud-init-output.log`.
- Cannot reach the database: use `$DB_HOST`, not a hand-typed endpoint.
- Dump cut off: the scheduled stop hit it. Start earlier, or disable that night's stop with `aws ssm update-maintenance-window --window-id <db_dump_host_stop_window_id> --no-enabled`.
