# PaxosKV

A cluster-wide key-value store based on Basic Paxos on BEAM.

`PaxosKV` is meant to be a useful building block when you need to create CP
systems (in terms of the CAP theorem).

## Usage

First of all, there's a helper task called `node` that can help you with
starting your cluster. If you enter the following lines in different terminal
windows, you can easily start a 3 node cluster right away:

    iex -S mix node 1

    iex -S mix node 2

    iex -S mix node 3

If you want to start a node without the `IEx` shell, just use

    mix node 1

    mix node 2

    mix node 3

Paxos is a consensus algo based on majority votes, so it is very important to
start a cluster before you can do anything with it. The expected (ideal) number
of nodes in the cluster is by default set to `3`. This is what we call the
cluster size. If you start only one node, it is not able to associate any key
with any value. A `put(key, value)` call will be blocked until at least one
more node spins up, and the cluster reaches quorum. (That is more than half of
the nodes out of `cluster_size` is up. `PaxosKV` logs the size of the network
and when it reache quorum.)

### Setting values

The main function you need to know is `PaxosKV.put(key, value)`. This is used
to associate `value` with the `key`. Both `key` and `value` can be any term.
(The only restriction is that it is discouraged to use annon functions, because
the values are shared among nodes, and differences between ERTS versions across
the cluster can cause problems with functions.)

Once a key-value pair is set, there's no way you can change the value of the
key. The cluster will remember it forever and a day. Further calls to
`PaxosKV.put(key, value)` with a different value will just return the
originally set value.

### Reading values

`PaxosKV.get(key)` and `PaxosKV.get(key, default)` can be used to read values
associated with `key`. `dafault` is returned when there's no value associated
with `key` in the cluster.

Please avoid using `PaxosKV.get` when possible because in the background it may
triggers a Paxos round, and that can be expensive, and can even change the
state of the network in case there was an unfinished Paxos round. Use `put`
whenever possible. `put` always returns the value choosen by the network.

### Erase a key from the key-value store

Well, that is normally not possible. A key is set to a specific value in the
system if a majority of the acceptors accepts the value. In order to delete a
key from the store, you need a coordinated effort among the nodes to delete the
key from all the acceptors at the same time. If only one of them does not
delete the key for some reason (network problem, lost message, whatever), the
value sneaks back to the cluster when the next `put(key, value)` is called.
This is why there's no `erase` or `delete` function in `PaxosKV`.

However, ther is a way to get rid of the old, tired keys, but that's a strange
one. When setting a key-value pair, you can attach a process identifier to the
key with this syntax:

    PaxosKV.put(key, value, pid: pid)

The attached `pid` is then monitored by all acceptors. When the monitor goes
down, the key is considered no longer valid, and it is erased from the state of
the acceptors.

Monitor down messages don't get lost. They are delivered even when a remote pid
is monitored and the remote host is disconnected. In `PaxosKV` this is
beneficial. If a process also monitors a pid, and a monditor down message is
received, the process has the chance to re-register the key in PaxosKV.

You can check the pid associated with a `key` by calling `PaxosKV.pid(key)`. It
returns `nil` if there's no pid associated with the key, or there's no key
registered at all.

## Configuration

`PaxosKV` has only one meaningful parameter to set, and that is the size of
your BEAM cluster.

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
application controller. Second, you need to add the necessary `PaxosKV`
components to your supervisor, like this:

    children = [
      ...
      PaxosKV.Learner,
      PaxosKV.Acceptor,
      PaxosKV.Proposer,
      {PaxosKV.Cluster, cluster_size},
      ...
    ]

The order of the children matters, please stick with the order above. In this
case `cluster_size` has to be set by your appication explicitely. It is now
fully under your controll.

