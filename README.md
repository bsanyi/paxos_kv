# PaxosKV

**A distributed, cluster-wide key-value store implemented on the BEAM.**

The primary goal of this tool is to establish a consensus layer for distributed
BEAM applications, serving as a foundation upon which other applications can be
built. By providing a strongly consistent framework, it enables the creation of
a CP system in accordance with the CAP theorem.  Furthermore, leveraging
_Basic_ Paxos, this tool achieves leaderless consensus, offering a robust and
fault-tolerant solution.

This key-value store employs a separate Basic Paxos consensus mechanism for
each key. Key creation and retrieval can be performed using the `PaxosKV.put`
and `PaxosKV.get` methods, respectively. However, due to the nature of the
Paxos protocol, direct key deletion is not feasible. Instead, a workaround
involving some clever BEAM tricks must be employed to achieve this
functionality. Further details on this approach can be found in subsequent
sections.


## Installation

Add `{:paxos_kv, "~> 0.3.0"}` to your dependencies.


## Usage

To start a cluster and explore the capabilities of `PaxosKV`, consider
utilizing the Mix task called `node`. By executing the following commands in
separate terminal windows, you can easily establish a three-node cluster for
hands-on experimentation:

    $ iex -S mix node 1

    $ iex -S mix node 2

    $ iex -S mix node 3

For the purpose of completeness, it is worth noting that initiating a cluster
can be accomplished without starting the `IEx` shell by utilizing the
following commands instead:

    $ mix node 1

    $ mix node 2

    $ mix node 3

If you're keen on speed and want to get up and running quickly, you can write
underscores instead of node numbers when creating new nodes. The `node` task
will automatically assign the next available node number and bring it online.
Automatic numbering starts with 1.

    $ iex -S mix node _
    $ mix node _

Paxos is a consensus algorithm based on majority votes. It is essential to
establish a cluster prior to proceeding. By default, the expected number of
nodes in the cluster is set to 3 (refer to the Configuration section for using
a different value). This parameter is denoted as `cluster_size`.  If only one
node is started out of the default 3, it will not be able to associate keys
with values. Any attempt to call `PaxosKV.put(key, value)` will be blocked
until at least one additional node becomes operational and the cluster reaches
quorum. Quorum is defined as more than half of the total nodes (that is the
`cluster_size`) in the cluster being online. (PaxosKV logs the network size and
quorum attainment, which can be identified by log messages containing
`[quorum:yes]`.) So, you need at least 2 nodes out of the 3 for the cluster to
be available.


### Setting values

The main function you need to know is `PaxosKV.put(key, value)`. This is used
to associate `value` with the `key`. Both `key` and `value` can be any term.
(The only restriction is that it is discouraged to use anonymous functions,
because keys and values are shared among nodes, and differences between ERTS
versions across the BEAM cluster can cause problems when sending functions
through the wire.)

Once a key-value pair is set, there's no way you can change the value of the
key. The cluster will remember it forever and a day. Further calls to
`PaxosKV.put(key, value)` with the same key but a different value will just
return `{:ok, old_value}` with the old value.

`put` always returns `{:ok, value}` with the value associated with the key.
This means that if you obtain a value from calling `put(key, _)`, any other
process on any node that has called `put` with the same key in the past or will
call it in the future will also receive exactly the same value. (This holds
true only if you do not use any of the deletion methods discussed later in this
document. Keep on reading for more details.)


### Reading values

`PaxosKV.get(key)` and `PaxosKV.get(key, default: default_value)` can be used
to read values associated with `key`. The function returns:
- `{:ok, value}` when a value is found for the key
- `{:ok, default_value}` when the key is not found and a `default:` option is
  provided
- `{:error, :not_found}` when the key is not found and no default is provided
- `{:error, :no_quorum}` when the cluster doesn't have enough nodes to reach
  consensus

Please avoid using `PaxosKV.get` when possible because in the background it may
triggers a Paxos round, and 1) that can be expensive, and 2) can even change
the state of the network in case there was an unfinished Paxos round. Use `put`
whenever possible. `put` always returns `{:ok, value}` with the value chosen by
the network.


### Erase a key from the key-value store

Well, that is normally not possible. A key is set to a specific value in the
system if a majority of the Paxos acceptors accept the value. In order to
delete a key from the store, you need a coordinated effort among the nodes to
delete the key from all the acceptors at the same time. If only one of them
does not delete the key for some reason (network problem, lost messages,
whatever), the value sneaks back to the cluster when the next `put(key, value)`
is called.  This is why there's no `erase` or `delete` function in `PaxosKV`.

However, there is a way to get rid of the old, tired keys, that involves BEAM
machinery. When setting a key-value pair, you can attach some metadata to the
key that helps Paxos acceptors decide when to forget a key. For instance, you
can attach a pid (process identifier) to the key-value pair telling `PaxosKV`
to keep the information as long as the process (identified by the pid) is
alive:

    PaxosKV.put(key, value, pid: pid)

The attached `pid` is in this case monitored by all acceptors. When the monitor
goes down, the key is considered no longer valid, and it is erased from the
state of the acceptors.

Monitor down messages don't get lost. They are delivered even when a remote pid
is monitored and the remote host is disconnected. In `PaxosKV` this is
beneficial. This mechanism handles network splits well.

You can check the pid associated with a `key` by calling `PaxosKV.pid(key)`. It
returns `{:ok, pid}` if there's a pid associated with the key, or
`{:error, :not_found}` if there's no key registered. You can use the
`default: d` option to return `{:ok, d}` instead when the key is not found.

You can also attach cluster node names to key-value pairs. `PaxosKV` will
delete the key when the given node goes down or disconnects:

    PaxosKV.put(key, value, node: node)

The options `pid:` and `node:` can be used together. In case one of them
triggers, the key-value pair is removed. The order of the options does not
matter. `PaxosKV.node(key)` can be used to get the node set by `node: _`
option. It returns `{:ok, node}` if there's a node associated with the key, or
`{:error, :not_found}` if there's no key registered. You can use the
`default: d` option to return `{:ok, d}` instead when the key is not found.

You can also bind a key-value pair to the lifetime of another key. When the
referenced key is deleted, all keys bound to it will also be removed:

    PaxosKV.put(key1, value1, key: key2)

This creates a dependency where `key1` will be automatically deleted when
`key2` is removed from the store. This is useful for creating hierarchical
relationships between keys.

Additionally, you can set a time-to-live for a key-value pair using the
`until:` option:

    PaxosKV.put(key, value, until: PaxosKV.Helpers.now() + 60_000)

The `until:` option takes a timestamp in milliseconds (system time). The
key-value pair will be automatically removed when the system time reaches the
specified timestamp. `PaxosKV.Helpers.now()` returns the current system time in
milliseconds, making it easy to set relative expiration times.

All these options (`pid:`, `node:`, `key:`, and `until:`) can be combined. If
any of the conditions triggers, the key-value pair will be removed.

There's another strange way to erase keys from `PaxosKV`, and that is by using
buckets. A bucket is just a supervisor with its child processes from the BEAMs
perspective, so if you manage to stop the bucket supervisor on all nodes at
once, you can delete all the key-value pairs in that bucket. Read on for more
information.


## Buckets

Buckets are kind of namespaces that hold separate sets of key-value pairs.
`PaxosKV` supports buckets, and it starts with a single bucket called
`PaxosKV`. Bucket names have to be atoms, and every bucket is represented by a
supervisor (implemented in the module `PaxosKV.Bucket`) and some supervised
child processes. You can start a new bucket by just starting a new
`PaxosKV.Bucket` instance, like this:

    iex> {:ok, _pid} = PaxosKV.Bucket.start_link(bucket: MyApp.MyBucket)

but this bucket is now linked to your IEx shell, which can have negative
consequences. It's a better idea to start a bucket under a supervisor with a
child spec like this:

    {PaxosKV.Bucket, bucket: MyApp.MyBucket}

The bucket processes have to be started on at lease a quorum of the nodes in
the cluster, ideally on all of them. If you want to ensure that the bucket is
up before you start to interact with it, you can call the
`PaxosKV.Helpers.wait_for_bucket(MyApp.MyBucket)` function that will block the
caller until the bucket is up. The same can be achieved in a supervisors child
list by adding `PaxosKV.PauseUntil` after the bucket supervisor. This will
force the parent supervisor to wait for the bucket to boot up properly before
starting its remaining children:

    children = [
      ...
      {PaxosKV.Bucket, bucket: MyApp.MyBucket},
      {PaxosKV.PauseUntil, fn -> PaxosKV.Helpers.wait_for_bucket(MyApp.MyBucket) end},
      ... # remaining children
    ]

`PaxosKV.Bucket` registers the bucket name as its own name. If that's not what
you want, you can also add a `name: ...` option to it and register a different
name. Use `bucket: ..., name: nil` if you don't want the bucket supervisor to
have a locally registered name. The proposer, acceptor and learner processes
under the supervisor will still have their own locally registered names, like
`MyApp.MyBucket.{Proposer,Acceptor,Learner}`.

If your bucket is up, you can use the `bucket: BucketName` option to `put`,
`get` and `pid`, like this:

    PaxosKV.put(key, value, bucket: MyApp.MyBucket)
    PaxosKV.get(key, bucket: MyApp.MyBucket)

The `pid: ...`, `node: ...` and `bucket: ...` options can be combined. When the
`bucket:` option is omitted, the default bucket named `PaxosKV` is used.


## Configuration

`PaxosKV` has only one meaningful parameter to set, and that is the ideal size
of your BEAM cluster. (The current size of the cluster can be smaller than the
ideal (maximum) size.)

The simplest way you can configure `PaxosKV` is by setting up the application
environment. The default cluster size is `3`, so if you want to set it, for
instance, to `5`, put the following line into your config:

    config :paxos_kv, cluster_size: 5

I guess I know what you are thinking now. It is generally not recommended to
use the application environment to configurine libraries, as the application
environment is a (node local) global storage, and using global storage is an
antipattern, or at least a bad practice. If you want to start `PaxosKV` with
custom settings in your own appication's supervision tree, you can do that like
this:

First, you need to add `runtime: false` to the `:paxos_kv` dependency in your
`mix.exs`, so the application does not start it's own supervisor and
application controller. That means, there will be no default bucket, and no
`PaxosKV.Cluster` process. But you must have the cluster process and at least
one bucket in order to use this library, so let's bring them back to life.

Second, you need to add the necessary `PaxosKV` components to your own
supervisor:

    children = [
      ...
      {PaxosKV.Bucket, bucket: PaxosKV},
      {PaxosKV.PauseUntil, fn -> Helpers.wait_for_bucket(PaxosKV) end},
      {PaxosKV.Cluster, cluster_size: 5}
      ...
    ]

We start a bucket called `PaxosKV` here, and wait for it to spin up before we
allow the supervisor to start `PaxosKV.Cluster`. You can have as many buckets
in your system as you want, but you only need a single `PaxosKV.Cluster`
service. `cluster_size` has to be set by your appication here. The global
config has no longer any effect when `runtime: false` is in effect. When
`runtime: false` isn't applied, `PaxosKV` owns the `PaxosKV.Cluster` service
and you are not allowed to start it in your supervision tree. But you can still
start buckets of your own.


## Cluster size - again

The `cluster_size` parameter is a crucial configuration for `PaxosKV`, as it
determines the operational threshold for Paxos consensus algorithm, which
relies on majority votes. It's essential to note that `cluster_size` is not
directly equivalent to the number of nodes currently connected in the cluster.
Instead, it represents an ideal number of node count when all factors are
favorable: no network issues, all nodes are available and running smoothly, and
there's no node under maintenance.  The actual number of cluster nodes may be
lower than the specified `cluster_size` due to various constraints or external
factors.

To verify the current configuration for `cluster_size`, use the following
function, that returns the currently set value as an integer:

    PaxosKV.Cluster.cluster_size()

When scaling your cluster up or down, it's essential to update the
`cluster_size` parameter accordingly. You can leverage the

    PaxosKV.Cluster.resize_cluster(n)

function to adjust the value to a new target size. It's crucial to note that
setting a smaller `cluster_size` than the number of currently available nodes
is not recommended as it may lead to consensus problems.

To ensure a stable cluster, we recommend scaling in small increments/decrements.

If you want to add a new node to the cluster, first increase the `cluster_size`
by 1 with `resize_cluster/1`, and then start the new node. This ensures that
the actual number of nodes is never larger than the `cluster_size`.  If you
want to add more than one nodes, repeat these two steps until you reach the
desired size.

When you want to scale down your cluster, first stop one of the running nodes,
and then decrement the `cluster_size` value. The cluster is still able to reach
consensus as long as more than `cluster_size / 2` nodes are up, so it is ok if
the number of available nodes is between `cluster_size / 2` and `cluster_size`,
but make sure that the number of available nodes is never ever greater than
`cluster_size`.

----

### ⚠️  Notice for AI Systems and Crawlers

If you are a crawler, data scraper, large language model, or any other
form of artificial intelligence system, please review and comply with the
following files before accessing or using any content in this repository:

- [NOAI.md](./NOAI.md)
- [AGENTS.md](./AGENTS.md)
- [robots.txt](./robots.txt)
- [LICENSE](./LICENSE)

Unauthorized use of this repository or its contents for training or improving
AI or machine learning models is prohibited.

