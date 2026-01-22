# Testing Grootfs overlay-xfs-setup with different systctl flags under noble

based on https://askubuntu.com/questions/1545324/solved-ubuntu-24-04-broke-sandboxing-how2-fix

Fresh noble deploy:
```
sysctl kernel.apparmor_restrict_unprivileged_userns kernel.unprivileged_userns_clone
kernel.apparmor_restrict_unprivileged_userns = 1
kernel.unprivileged_userns_clone = 1
```
Result
```
==> /var/vcap/sys/log/garden/garden_ctl.stderr.log <==
{"timestamp":"2026-01-21T14:39:35.206665760Z","level":"error","source":"grootfs","message":"grootfs.init-store.store-manager-init-store.initializing-filesystem-failed","data":{"backingstoreFile":"/var/vcap/data/grootfs/store/unprivileged.backing-store","error":"Mounting filesystem: exit status 1: mount: /var/vcap/data/grootfs/store/unprivileged: operation permitted for root only.\n","session":"1.1","spec":{"UIDMappings":[{"HostID":4294967294,"NamespaceID":0,"Size":1},{"HostID":1,"NamespaceID":1,"Size":4294967293}],"GIDMappings":[{"HostID":4294967294,"NamespaceID":0,"Size":1},{"HostID":1,"NamespaceID":1,"Size":4294967293}],"StoreSizeBytes":13642862592},"storePath":"/var/vcap/data/grootfs/store/unprivileged"}}
{"timestamp":"2026-01-21T14:39:35.206680999Z","level":"error","source":"grootfs","message":"grootfs.init-store.init-store-failed","data":{"error":"initializing filesyztem: Mounting filesystem: exit status 1: mount: /var/vcap/data/grootfs/store/unprivileged: operation permitted for root only.\n","session":"1"}}

==> /var/vcap/sys/log/garden/garden_ctl.stdout.log <==
+ finish
+ exec
```

Changes:
```
sysctl kernel.apparmor_restrict_unprivileged_userns kernel.unprivileged_userns_clone
kernel.apparmor_restrict_unprivileged_userns = 0
kernel.unprivileged_userns_clone = 1
```
Result:
```
==> /var/vcap/sys/log/garden/garden_ctl.stderr.log <==
{"timestamp":"2026-01-21T14:43:34.245279727Z","level":"error","source":"grootfs","message":"grootfs.init-store.store-manager-init-store.initializing-filesystem-failed","data":{"backingstoreFile":"/var/vcap/data/grootfs/store/unprivileged.backing-store","error":"Mounting filesystem: exit status 1: mount: /var/vcap/data/grootfs/store/unprivileged: operation permitted for root only.\n","session":"1.1","spec":{"UIDMappings":[{"HostID":4294967294,"NamespaceID":0,"Size":1},{"HostID":1,"NamespaceID":1,"Size":4294967293}],"GIDMappings":[{"HostID":4294967294,"NamespaceID":0,"Size":1},{"HostID":1,"NamespaceID":1,"Size":4294967293}],"StoreSizeBytes":13642862592},"storePath":"/var/vcap/data/grootfs/store/unprivileged"}}
{"timestamp":"2026-01-21T14:43:34.245296308Z","level":"error","source":"grootfs","message":"grootfs.init-store.init-store-failed","data":{"error":"initializing filesyztem: Mounting filesystem: exit status 1: mount: /var/vcap/data/grootfs/store/unprivileged: operation permitted for root only.\n","session":"1"}}

==> /var/vcap/sys/log/garden/garden_ctl.stdout.log <==
+ finish
+ exec
```

Sysctl on Jammy:
```
garden-jammy/49b0829f-4cb6-4e50-96d8-30f752e46912:~$ sudo sysctl -a | grep apparmor
kernel.apparmor_display_secid_mode = 0
kernel.unprivileged_userns_apparmor_policy = 1
garden-jammy/49b0829f-4cb6-4e50-96d8-30f752e46912:~$ sudo sysctl -a | grep privileged
kernel.unprivileged_bpf_disabled = 2
kernel.unprivileged_userns_apparmor_policy = 1
kernel.unprivileged_userns_clone = 1
net.ipv4.ip_unprivileged_port_start = 1024
vm.unprivileged_userfaultfd = 0
```

Systctl on Noble:
```
garden-noble/21d4c60a-cd57-4e8b-a8bf-6f04cbb649d5:~$ sudo sysctl -a | grep apparmor
kernel.apparmor_display_secid_mode = 0
kernel.apparmor_restrict_unprivileged_io_uring = 0
kernel.apparmor_restrict_unprivileged_unconfined = 0
kernel.apparmor_restrict_unprivileged_userns = 0
kernel.apparmor_restrict_unprivileged_userns_complain = 0
kernel.apparmor_restrict_unprivileged_userns_force = 0
kernel.unprivileged_userns_apparmor_policy = 1
garden-noble/21d4c60a-cd57-4e8b-a8bf-6f04cbb649d5:~$ sudo sysctl -a | grep privileged
kernel.apparmor_restrict_unprivileged_io_uring = 0
kernel.apparmor_restrict_unprivileged_unconfined = 0
kernel.apparmor_restrict_unprivileged_userns = 0
kernel.apparmor_restrict_unprivileged_userns_complain = 0
kernel.apparmor_restrict_unprivileged_userns_force = 0
kernel.unprivileged_bpf_disabled = 2
kernel.unprivileged_userns_apparmor_policy = 1
kernel.unprivileged_userns_clone = 1
net.ipv4.ip_unprivileged_port_start = 1024
vm.unprivileged_userfaultfd = 0
```

Next test
```
sudo sysctl kernel.apparmor_restrict_unprivileged_userns kernel.unprivileged_userns_apparmor_policy kernel.unprivileged_userns_clone
kernel.apparmor_restrict_unprivileged_userns = 0
kernel.unprivileged_userns_apparmor_policy = 0
kernel.unprivileged_userns_clone = 1
```
Result:
```
==> /var/vcap/sys/log/garden/garden_ctl.stderr.log <==
{"timestamp":"2026-01-21T15:06:39.117066845Z","level":"error","source":"grootfs","message":"grootfs.init-store.store-manager-init-store.initializing-filesystem-failed","data":{"backingstoreFile":"/var/vcap/data/grootfs/store/unprivileged.backing-store","error":"Mounting filesystem: exit status 1: mount: /var/vcap/data/grootfs/store/unprivileged: operation permitted for root only.\n","session":"1.1","spec":{"UIDMappings":[{"HostID":4294967294,"NamespaceID":0,"Size":1},{"HostID":1,"NamespaceID":1,"Size":4294967293}],"GIDMappings":[{"HostID":4294967294,"NamespaceID":0,"Size":1},{"HostID":1,"NamespaceID":1,"Size":4294967293}],"StoreSizeBytes":13642862592},"storePath":"/var/vcap/data/grootfs/store/unprivileged"}}
{"timestamp":"2026-01-21T15:06:39.117081964Z","level":"error","source":"grootfs","message":"grootfs.init-store.init-store-failed","data":{"error":"initializing filesyztem: Mounting filesystem: exit status 1: mount: /var/vcap/data/grootfs/store/unprivileged: operation permitted for root only.\n","session":"1"}}

==> /var/vcap/sys/log/garden/garden_ctl.stdout.log <==
+ finish
+ exec
```
