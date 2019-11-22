FROM ruby:2.5

WORKDIR /root

COPY ./cloud-mu-*.gem /root

EXPOSE 2260

RUN apt-get update
RUN apt-get install -y ruby2.5-dev g++ bind-utils
RUN gem install ./cloud-mu-*.gem thin -N
RUN mkdir -p /opt/mu/etc/
RUN mkdir -p /usr/local/ruby-current/lib/ruby/gems/2.5.0/gems/var/
RUN rm cloud-mu-*.gem
RUN apt-get remove -y make g++
CMD /usr/sbin/init
