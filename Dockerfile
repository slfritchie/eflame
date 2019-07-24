FROM bryanhuntesl/alpine-erlang:20.3.8.22-fritchies.eflame

COPY . .

RUN wget https://github.com/erlang/rebar3/releases/download/3.5.3/rebar3 \
-O /usr/local/bin/rebar3 \
&& chmod 755 /usr/local/bin/rebar3 \
&& rebar3 as prod release

FROM bryanhuntesl/alpine-erlang:20.3.8.22-fritchies.eflame

COPY --from=0 /opt/app/_build/prod/rel ./rel

ENTRYPOINT ["/rel/eflame/bin/eflame"]

CMD ["console"]
