FROM ruby:3.4.4-bookworm AS builder

RUN apt-get update \
 && apt-get install --no-install-recommends -y build-essential libpq-dev \
 && rm -rf /var/lib/apt/lists/* \
 && gem install pg -v 1.6.3 --no-document \
 && ruby -rpg -e 'abort unless PG::VERSION == "1.6.3"' \
 && ruby -rpg -e 'puts PG::VERSION' > /usr/local/typed_eav_pg_version

FROM ruby:3.4.4-bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install --no-install-recommends -y libpq5 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY --from=builder /usr/local/typed_eav_pg_version /usr/local/typed_eav_pg_version
RUN ruby -rpg -e 'abort unless PG::VERSION == "1.6.3"'

WORKDIR /workspace
COPY . /workspace

ENTRYPOINT ["ruby", "bench/scalar_index_benchmark.rb"]
