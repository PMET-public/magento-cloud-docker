FROM debian:latest

RUN apt-get update

RUN apt-get install -y python-distutils-extra git build-essential

RUN git clone https://github.com/adsr/phpspy.git 

WORKDIR phpspy 

RUN make

