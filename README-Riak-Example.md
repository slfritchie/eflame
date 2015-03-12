
# A detailed example of investigations using flame graphs and Riak

## In our very first example, as described in
[README.md](README.md), we generated a flame graph for all Riak
processes that were executing during:

* A time window of 10 seconds
* We ran 25 Riak `get` requests while inside the measurement time window

... and we got something that looks like this:

<a href="http://www.snookles.com/scotttmp/eflame2/riak.0.svg"><img src="http://www.snookles.com/scotttmp/eflame2/riak.0.png"></a>

Wow, that's impossible to read without zooming in via the SVG version
of the image.

However, we know that the flame graphs are colored with "SLEEP" time
as a purple bar at the top of the stack.  We can use this command to
strip out all Erlang process sleep time and create a new graph:

    cat /tmp/ef.test.0.out | grep -v 'SLEEP ' | \
        ./flamegraph.riak-color.pl > /tmp/output.0.nosleep.svg

<a href="http://www.snookles.com/scotttmp/eflame2/riak.1.svg"><img src="http://www.snookles.com/scotttmp/eflame2/riak.1.png"></a>

Now we can see a few PIDs near the bottom: `0.1333.0` and `0.28843.0`
and so on.  But this is still too cluttered: there are over 150 Erlang
processes in this graph .......
