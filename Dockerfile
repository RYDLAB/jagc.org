FROM ubuntu:15.10
MAINTAINER Maxim Kolodyazhny <mw26@rydlab.ru>

VOLUME /opt/share

RUN apt-get update\
&& apt-get -y install apt-utils\
&& apt-get -y install make\
&& apt-get -y install gcc\ 
&& apt-get -y install perl\
\
&& apt-get -y install curl\
&& curl -L http://cpanmin.us | perl - App::cpanminus\
&& cpanm IPC::Run\ 
&& cpanm JSON::PP\
\
&& apt-get -y install haskell-platform\
\
&& apt-get -y install erlang\
\
&& apt-get -y install php5-cli\
\
&& apt-get -y install python2.7\
&& apt-get -y install python3.5\
\
&& apt-get -y install ruby1.9.1\
\
&& apt-get -y install ruby2.2\
\
&& apt-get -y install nodejs\
\
#&& apt-get purge -y gcc\
#&& apt-get purge -y make\
&& apt-get purge -y curl\
&& chmod 755 /opt/share -R

USER nobody
WORKDIR /dev/shm
ENV TMPDIR="/dev/shm"
