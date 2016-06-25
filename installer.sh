#!/bin/bash

source ./variables.conf
XMPP_IP=/sbin/ifconfig eth1 | grep 'inet addr:' | cut -d: -f2 | awk '{ print $1}'
BROKER_IP=/sbin/ifconfig eth0 | grep 'inet addr:' | cut -d: -f2 | awk '{ print $1}'

install_dependencies() {
    echo 'deb http://pkg.mytestbed.net/ubuntu precise/ ' >> /etc/apt/sources.list \
    && apt-get update
    apt-get install -y --force-yes \
       build-essential \
       dnsmasq \
       frisbee \
       git \
       libsqlite3-dev \
       libreadline6-dev \
       libssl-dev \
       libyaml-dev \
       libxml2-dev \
       libxmlsec1-dev \
       libxslt-dev \
       ntp \
       syslinux \
       xmlsec1 \
       wget \
       zlib1g-dev

    cd /tmp \
       && wget http://ftp.ruby-lang.org/pub/ruby/2.1/ruby-2.1.5.tar.gz \
       && tar -xvzf ruby-2.1.5.tar.gz \
       && cd ruby-2.1.5/ \
       && ./configure --prefix=/usr/local \
       && make \
       && make install \
       && rm -rf /tmp/ruby

    gem install bundler --no-ri --no-rdoc
}

install_broker() {
    #if $OMF_SFA_HOME directory does not exist or is empty
    if [ ! "$(ls -A $OMF_SFA_HOME)" ] || [ ! "$(ls -A /root/.omf)" ]; then
        echo "###############INSTALLATION OF THE MODULES###############"
        #Start of Broker installation
        echo "###############GIT CLONE OMF_SFA REPOSITORY###############"
        cd /root
        git clone https://github.com/viniciusgb4/omf_sfa.git
        cd $OMF_SFA_HOME
        echo "###############INSTALLING OMF_SFA###############"
        bundle install

        echo "###############RAKE DB:MIGRATE###############"
        rake db:migrate

        echo "###############CREATING DEFAULT SSH KEY###############"
        ssh-keygen -b 2048 -t rsa -f /root/.ssh/id_rsa -q -N ""

        ##START OF CERTIFICATES CONFIGURATION
        echo "###############CONFIGURING OMF_SFA CERTIFICATES###############"
        mkdir -p /root/.omf/trusted_roots
        omf_cert.rb --email root@$DOMAIN -o /root/.omf/trusted_roots/root.pem --duration 50000000 create_root
        omf_cert.rb -o /root/.omf/am.pem  --geni_uri URI:urn:publicid:IDN+$AM_SERVER_DOMAIN+user+am --email am@$DOMAIN --resource-id xmpp://am_controller@$XMPP_DOMAIN --resource-type am_controller --root /root/.omf/trusted_roots/root.pem --duration 50000000 create_resource
        omf_cert.rb -o /root/.omf/user_cert.pem --geni_uri URI:urn:publicid:IDN+$AM_SERVER_DOMAIN+user+root --email root@$DOMAIN --user root --root /root/.omf/trusted_roots/root.pem --duration 50000000 create_user

        openssl rsa -in /root/.omf/am.pem -outform PEM -out /root/.omf/am.pkey
        openssl rsa -in /root/.omf/user_cert.pem -outform PEM -out /root/.omf/user_cert.pkey
        ##END OF CERTIFICATES CONFIGURATION

        echo "###############CONFIGURING OMF_SFA AS UPSTART SERVICE###############"
        cp init/omf-sfa.conf /etc/init/ && sed -i '/chdir \/root\/omf\/omf_sfa/c\chdir \/root\/omf_sfa' /etc/init/omf-sfa.conf
        #End of Broker installation
    fi
}

install_nitos_rcs() {
    if ! gem list nitos_testbed_rc -i; then
        #Start of NITOS Testbed RCs installation
        echo "###############INSTALLING NITOS TESTBED RCS###############"
        gem install nitos_testbed_rc
        install_ntrc

        ##START OF CERTIFICATES CONFIGURATION
        echo "###############CONFIGURING NITOS TESTBED RCS CERTIFICATES###############"
        omf_cert.rb -o /root/.omf/user_factory.pem --email user_factory@$DOMAIN --resource-type user_factory --resource-id xmpp://user_factory@$XMPP_DOMAIN --root /root/.omf/trusted_roots/root.pem --duration 50000000 create_resource
        omf_cert.rb -o /root/.omf/cm_factory.pem --email cm_factory@$DOMAIN --resource-type cm_factory --resource-id xmpp://cm_factory@$XMPP_DOMAIN --root /root/.omf/trusted_roots/root.pem --duration 50000000 create_resource
        omf_cert.rb -o /root/.omf/frisbee_factory.pem --email frisbee_factory@$DOMAIN --resource-type frisbee_factory --resource-id xmpp://frisbee_factory@$XMPP_DOMAIN --root /root/.omf/trusted_roots/root.pem --duration 50000000 create_resource
        cp -r /root/.omf/trusted_roots/ /etc/nitos_testbed_rc/
        ##END OF CERTIFICATES CONFIGURATION
        #End of NITOS Testbed RCs installation
    fi
}

configure_testbed() {

    ##START OF - COPING CONFIGURATION FILES
    echo "###############COPYING CONFIGURATION FILES TO THE RIGHT PLACE###############"
    cp -r ./config-files/* /
    ##END OF - COPING CONFIGURATION FILES

    #START OF PXE CONFIGURATION
    echo "###############PXE CONFIGURATION###############"
    ln -s /usr/lib/syslinux/pxelinux.0 /tftpboot/
    ln -s /tftpboot/pxelinux.cfg/pxeconfig /tftpboot/pxelinux.cfg/01-00:03:1d:0c:23:46
    ln -s /tftpboot/pxelinux.cfg/pxeconfig /tftpboot/pxelinux.cfg/01-00:03:1d:0c:47:48
    cp -rf /etc/dnsmasq.conf /etc/dnsmasq.conf.bkp
    cp -rf /root/dnsmasq.conf /etc/dnsmasq.conf
    cat /root/hosts >> /etc/hosts
    #END OF PXE CONFIGURATION
}

start_broker() {
    echo "Executing omf_sfa"
    bundle exec ruby -I lib lib/omf-sfa/am/am_server.rb start &> /var/log/omf-sfa.log &
}

start_nitos_rcs() {
    echo "Executing NITOS Testbed RCs"

    user_proxy &> /var/log/ntrc/user_proxy.log &
    frisbee_proxy &> /var/log/ntrc/frisbee_proxy.log &
    cm_proxy &> /var/log/ntrc/cm_proxy.log &
}

insert_nodes() {
    /root/omf_sfa/bin/create_resource -t node -c /root/omf_sfa/bin/conf.yaml -i /root/resources.json
}

log_broker() {
    tail -f /var/log/omf-sfa.log
}

uninstall_broker() {
    bundle exec ruby -I lib lib/omf-sfa/am/am_server.rb stop
    rm -rf $OMF_SFA_HOME
    echo "Uninstall NITOS Testbed RCs?"
    read opcao
    case $opcao in
        y) unistall_nitos_rcs ;;
        Y) unistall_nitos_rcs ;;
        *) ;;
    esac
}

unistall_nitos_rcs() {
    gem unistall nitos_testbed_rc
    rm -rf /root/.omf
    rm -rf /etc/nitos_testbed_rc
}

install_docker() {

    if [ "$(ls -A /etc/apt/sources.list.d/docker.list)" ]; then
        rm -rf /etc/apt/sources.list.d/docker.list
    fi

    echo "deb https://apt.dockerproject.org/repo ubuntu-trusty main" >> /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --force-yes apt-transport-https ca-certificates \
    && apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D \
    && apt-get update \
    && apt-get purge -y --force-yes lxc-docker \
    && apt-cache policy docker-engine \
    && apt-get install -y --force-yes linux-image-extra-$(uname -r) \
    && apt-get install -y --force-yes apparmor \
    && apt-get install -y --force-yes docker-engine \
    && service docker start
}

install_docker_compose() {
    curl -L https://github.com/docker/compose/releases/download/1.6.2/docker-compose-`uname -s`-`uname -m` > /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
}

install_amqp_server() {
    apt-get install rabbitmq-server
    echo "$AMQP_DOMAIN  amqp_server" >> /etc/hosts
}

install_xmpp_server() {
    cd /root
    git clone https://github.com/viniciusgb4/docker-omf6.git
    cd /root/docker-omf6
    docker-compose up -d pubsub
}

install_testbed() {
    install_dependencies
    install_docker
    install_docker_compose
    #install_amqp_server
    install_xmpp_server
    install_broker
    install_nitos_rcs
    configure_testbed

    #start_broker
    #start_nitos_rcs
}

main() {
    echo "------------------------------------------"
    echo "Opções:"
    echo
    echo "1. Install Testbed"
    echo "2. Install only Broker"
    echo "3. Install only NITOS Testbed RCs"
    echo "4. Uninstall Broker"
    echo "5. Uninstall NITOS Testbed RCs"
    echo "6. Exit"
    echo
    echo -n "Choose an option..."
    read opcao
    case $opcao in
    1) install_testbed ;;
    2) install_broker ;;
    3) install_nitos_rcs ;;
    4) uninstall_broker ;;
    5) unistall_nitos_rcs ;;
    *) exit ;;
    esac
}

main