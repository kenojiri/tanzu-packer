#!/bin/bash

set -exo pipefail

if test -z "$GITHUB_AUTH_CREDS"; then
  export CURL=curl
else
  export CURL="curl -k -u ${GITHUB_AUTH_CREDS}"
fi
VCC_VERSION=$(${CURL} -s https://api.github.com/repos/vmware-labs/vmware-customer-connect-cli/releases/latest | jq -r .tag_name)
PIVNET_VERSION=$(${CURL} -s https://api.github.com/repos/pivotal-cf/pivnet-cli/releases/latest | jq -r .tag_name | sed 's/v//')
HELM_VERSION=$(${CURL} -s https://api.github.com/repos/helm/helm/releases/latest | jq -r .tag_name)
KUSTOMIZE_VERSION=$(${CURL} -s https://api.github.com/repos/kubernetes-sigs/kustomize/releases/latest | jq -r .tag_name | awk -F/ '{print $2}')

BUILDDIR="BUILD-$(date +%Y%m%d%H%M%S.%N)"
mkdir -p ${BUILDDIR}
cd ${BUILDDIR}

CLUSTER_NAME=$(echo ${GOVC_RESOURCE_POOL} | awk -F/ '{print $4}')
cat <<EOF > variables.json
{
  "vcenter_server":"${GOVC_URL}",
  "vcenter_username":"${GOVC_USERNAME}",
  "vcenter_password":"${GOVC_PASSWORD}",
  "datastore":"${GOVC_DATASTORE}",
  "network": "${GOVC_NETWORK}",
  "folder": "${VM_FOLDER_NAME}",
  "vm_name": "${VM_NAME}",
  "host":"${ESXI_HOST}",
  "cluster": "${CLUSTER_NAME}",
  "ssh_username": "${VM_USERNAME}",
  "ssh_password": "${VM_PASSWORD}"
}
EOF

mkdir -p http
touch http/meta-data
VM_PASSWORD_HASH=$(openssl passwd -6 "${VM_PASSWORD}")
cat <<EOF > http/user-data
#cloud-config
autoinstall:
  version: 1
  apt:
    geoip: true
    preserve_sources_list: false
    primary:
    - arches: [amd64, i386]
      uri: http://us.archive.ubuntu.com/ubuntu
    - arches: [default]
      uri: http://ports.ubuntu.com/ubuntu-ports
  users:
  - default
  - name: ${VM_USERNAME}
    lock_passwd: false
    passwd: "${VM_PASSWORD_HASH}"
  identity:
    hostname: ${VM_NAME}
    username: ${VM_USERNAME}
    password: "${VM_PASSWORD_HASH}"
  locale: en_US
  write_files:
  - path: /etc/ssh/sshd_config
    content: |
      Port 22
      Protocol 2
      HostKey /etc/ssh/ssh_host_rsa_key
      HostKey /etc/ssh/ssh_host_dsa_key
      HostKey /etc/ssh/ssh_host_ecdsa_key
      HostKey /etc/ssh/ssh_host_ed25519_key
      UsePrivilegeSeparation yes
      KeyRegenerationInterval 3600
      ServerKeyBits 1024
      SyslogFacility AUTH
      LogLevel INFO
      LoginGraceTime 120
      PermitRootLogin yes
      StrictModes no
      RSAAuthentication yes
      PubkeyAuthentication no
      IgnoreRhosts yes
      RhostsRSAAuthentication no
      HostbasedAuthentication no
      PermitEmptyPasswords no
      ChallengeResponseAuthentication no
      X11Forwarding yes
      X11DisplayOffset 10
      PrintMotd no
      PrintLastLog yes
      TCPKeepAlive yes
      AcceptEnv LANG LC_*
      Subsystem sftp /usr/lib/openssh/sftp-server
      UsePAM yes
      AllowUsers ${VM_USERNAME}
  ssh:
    allow-pw: true
    install-server: true
  user-data:
    disable_root: false
  storage:
    layout:
      name: direct
    config:
    - type: disk
      id: disk0
      match:
        size: largest
    - type: partition
      id: boot-partition
      device: disk0
      size: 500M
    - type: partition
      id: root-partition
      device: disk0
      size: -1
  late-commands:
  - echo "${VM_USERNAME} ALL=(ALL) NOPASSWD:ALL" > /target/etc/sudoers.d/${VM_USERNAME}
EOF

mkdir -p script
cat <<EOF > script/install.sh
#!/bin/bash
set -ex

### deb packages
apt-get update
sh -c "DEBIAN_FRONTEND=noninteractive \
    apt-get install -y -o Dpkg::Options::=\"--force-confnew\" \
    git jq tmux direnv unzip groff gnupg bash-completion \
    apt-transport-https software-properties-common \
    net-tools dnsutils ldap-utils netcat-openbsd nfs-common \
    openjdk-17-jdk \
    "
echo "***deb packages installed!***"

TMPDIR=/tmp/\$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 8 | head -n 1)
mkdir -p \${TMPDIR}

### TODO: vApp options -> netplan YAML
rm -f /etc/netplan/00-installer-config.yaml
cat <<EOT > /etc/netplan/00-config.yaml
network:
  version: 2
  ethernets:
    ens192:
      dhcp4: true
      optional: true
#      dhcp4: false
#      addresses:
#      - 10.220.16.61/27
#      routes:
#      - to: default
#        via: 10.220.16.62
#      nameservers:
#        addresses:
#        - 10.220.136.2
#        - 10.220.136.3
EOT
echo "***netplan reconfigured!***"

### govc (vCenter client CLI written in Go)
pushd \${TMPDIR}
  curl -L https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_x86_64.tar.gz -o govc.tgz
  tar zxvf govc.tgz
  install ./govc /usr/local/bin/
popd
echo "***govc installed!***"

### setup secondary disk
export GOVC_URL="${GOVC_URL}"
export GOVC_USERNAME="${GOVC_USERNAME}"
export GOVC_PASSWORD="${GOVC_PASSWORD}"
export GOVC_DATACENTER="${GOVC_DATACENTER}"
export GOVC_NETWORK="${GOVC_NETWORK}"
export GOVC_DATASTORE="${GOVC_DATASTORE}"
export GOVC_RESOURCE_POOL="${GOVC_RESOURCE_POOL}"
export GOVC_INSECURE=${GOVC_INSECURE}
govc vm.disk.create -vm ${VM_NAME} -name ${VM_NAME}/datadisk -size ${SECONDARY_DISK_SIZE}
parted /dev/sdb mklabel gpt
parted -s -a optimal /dev/sdb -- mkpart primary 2048s 100%
parted /dev/sdb print
mkfs.xfs /dev/sdb1
lsblk -f
mkdir -p /mnt/datadisk
mount /dev/sdb1 /mnt/datadisk
mkdir /mnt/datadisk/tanzu
mkdir /mnt/datadisk/helm
mkdir /mnt/datadisk/grype-db
mkdir -m 740 /mnt/datadisk/docker
ln -s /mnt/datadisk/docker /var/lib/docker
ls -la /mnt/datadisk
cat <<EOT | tee -a /etc/fstab
/dev/sdb1 /mnt/datadisk xfs defaults 0 0
EOT
echo "***secondary disk attached!***"

### Docker
curl -sSL https://get.docker.com/ | sh
usermod -aG docker ubuntu
echo "***Docker installed!***"

### Carvel
curl -L https://carvel.dev/install.sh | bash
echo "***Carvel installed!***"

### yq
pushd \${TMPDIR}
  curl -L https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/local/bin/yq
  chmod +x /usr/local/bin/yq
popd
echo "***yq installed!***"

### vcc (VMware Customer Connect CLI)
pushd \${TMPDIR}
  curl -L https://github.com/vmware-labs/vmware-customer-connect-cli/releases/download/${VCC_VERSION}/vcc-linux-${VCC_VERSION} -o /usr/local/bin/vcc
  chmod +x /usr/local/bin/vcc
popd
echo "***vcc installed!***"

### pivnet (VMware Tanzu Network CLI)
pushd \${TMPDIR}
  curl -L https://github.com/pivotal-cf/pivnet-cli/releases/download/v${PIVNET_VERSION}/pivnet-linux-amd64-${PIVNET_VERSION} -o /usr/local/bin/pivnet
  chmod +x /usr/local/bin/pivnet
popd
echo "***pivnet installed!***"

### inject environment variables for vcc and VMware Tanzu Network
export VCC_USER="${VMWUSER}"
export VCC_PASS="${VMWPASS}"
vcc get files -p vmware_tanzu_kubernetes_grid -s tkg -v ${TKG_VERSION}
pivnet login --api-token=${PIVNET_TOKEN}
echo "***vcc installed!***"

### download TKG assets from VMware Customer Connect site
cat <<EOT > /mnt/datadisk/tanzu/vcc-manifest.yml
product: vmware_tanzu_kubernetes_grid
subproduct: tkg
version: "${TKG_VERSION}"
filename_globs:
  - "tanzu-cli-bundle-linux-amd64.tar.gz"
  - "photon-3-kube-*.ova"
  - "kubectl-linux-*.gz"
  - "photon-4-harbor-*.ova"
  - "crashd-linux-amd64-*.tar.gz"
  - "velero-linux-*.gz"
EOT
vcc download -m /mnt/datadisk/tanzu/vcc-manifest.yml --accepteula -d -o /mnt/datadisk/tanzu
echo "***TKG assets downloaded!***"

### install tanzu CLI
pushd \${TMPDIR}
  tar zxvf /mnt/datadisk/tanzu/tanzu-cli-bundle-linux-amd64.tar.gz cli/core
  install cli/core/*/tanzu-core-linux_amd64 /usr/local/bin/tanzu
  tanzu init
popd
echo "***Tanzu CLI installed!***"

### download TKG images
mkdir /mnt/datadisk/tanzu/TKGimages
cd /mnt/datadisk/tanzu/TKGimages
tanzu isolated-cluster download-bundle --source-repo projects.registry.vmware.com/tkg --tkg-version v${TKG_VERSION}
echo "***TKG images downloaded!***"

### download TAP images
cd /mnt/datadisk/tanzu
export IMGPKG_REGISTRY_HOSTNAME=registry.tanzu.vmware.com
export IMGPKG_REGISTRY_USERNAME="${TANZUNET_USERNAME}"
export IMGPKG_REGISTRY_PASSWORD="${TANZUNET_PASSWORD}"
imgpkg copy -b registry.tanzu.vmware.com/tanzu-application-platform/tap-packages:${TAP_VERSION} --to-tar tap-packages-${TAP_VERSION}.tar --include-non-distributable-layers
TAP_BUILDSERVICE_DEPS_VERSION=\$(imgpkg tag list -i registry.tanzu.vmware.com/tanzu-application-platform/full-tbs-deps-package-repo --json | jq -r .Tables[].Rows[].name | grep "${TAP_BUILDSERVICE_DEPS_MINOR_VERSION}" | sort -rV | head -1)
imgpkg copy -b registry.tanzu.vmware.com/tanzu-application-platform/full-tbs-deps-package-repo:\${TAP_BUILDSERVICE_DEPS_VERSION} --to-tar=tbs-full-deps-v\${TAP_BUILDSERVICE_DEPS_VERSION}.tar
imgpkg copy -b registry.tanzu.vmware.com/app-service-adapter/tas-adapter-package-repo:${TAS_ADAPTER_VERSION} --to-tar tas-adapter-package-repo-v${TAS_ADAPTER_VERSION}.tar
echo "***TAP images downloaded!***"

### download TAP related assets from VMware Tanzu Network
# tanzu CLI bundle for TAP (tanzu-framework-bundle-linux)
FILEID=\$(pivnet product-files -p tanzu-application-platform -r ${TAP_VERSION} --format json | jq -r '.[] | select (.name == "tanzu-framework-bundle-linux") | .id')
pivnet download-product-files --product-slug='tanzu-application-platform' --release-version="${TAP_VERSION}" --product-file-id=\${FILEID}

# Tanzu GitOps Reference Implementation
FILEID=\$(pivnet product-files -p tanzu-application-platform -r ${TAP_VERSION} --format json | jq -r '.[] | select (.name == "Tanzu GitOps Reference Implementation") | .id')
pivnet download-product-files --product-slug='tanzu-application-platform' --release-version="${TAP_VERSION}" --product-file-id=\${FILEID}

# Tanzu Developer Tools for Visual Studio
FILEID=\$(pivnet product-files -p tanzu-application-platform -r ${TAP_VERSION} --format json | jq -r '.[] | select (.name == "Tanzu Developer Tools for Visual Studio") | .id')
pivnet download-product-files --product-slug='tanzu-application-platform' --release-version="${TAP_VERSION}" --product-file-id=\${FILEID}

# Tanzu App Accelerator Extension for Intellij
FILEID=\$(pivnet product-files -p tanzu-application-platform -r ${TAP_VERSION} --format json | jq -r '.[] | select (.name == "Tanzu App Accelerator Extension for Intellij") | .id')
pivnet download-product-files --product-slug='tanzu-application-platform' --release-version="${TAP_VERSION}" --product-file-id=\${FILEID}

# Tanzu App Accelerator Extension for Visual Studio Code
FILEID=\$(pivnet product-files -p tanzu-application-platform -r ${TAP_VERSION} --format json | jq -r '.[] | select (.name == "Tanzu App Accelerator Extension for Visual Studio Code") | .id')
pivnet download-product-files --product-slug='tanzu-application-platform' --release-version="${TAP_VERSION}" --product-file-id=\${FILEID}

# learning-center-workshop-samples
FILEID=\$(pivnet product-files -p tanzu-application-platform -r ${TAP_VERSION} --format json | jq -r '.[] | select (.name == "learning-center-workshop-samples.zip") | .id')
pivnet download-product-files --product-slug='tanzu-application-platform' --release-version="${TAP_VERSION}" --product-file-id=\${FILEID}

# Tanzu Developer Tools for Visual Studio Code
FILEID=\$(pivnet product-files -p tanzu-application-platform -r ${TAP_VERSION} --format json | jq -r '.[] | select (.name == "Tanzu Developer Tools for Visual Studio Code") | .id')
pivnet download-product-files --product-slug='tanzu-application-platform' --release-version="${TAP_VERSION}" --product-file-id=\${FILEID}

# Tanzu Application Platform GUI Blank Catalog
FILEID=\$(pivnet product-files -p tanzu-application-platform -r ${TAP_VERSION} --format json | jq -r '.[] | select (.name == "Tanzu Application Platform GUI Blank Catalog") | .id')
pivnet download-product-files --product-slug='tanzu-application-platform' --release-version="${TAP_VERSION}" --product-file-id=\${FILEID}

# Tanzu Application Platform GUI Yelb Catalog
FILEID=\$(pivnet product-files -p tanzu-application-platform -r ${TAP_VERSION} --format json | jq -r '.[] | select (.name == "Tanzu Application Platform GUI Yelb Catalog") | .id')
pivnet download-product-files --product-slug='tanzu-application-platform' --release-version="${TAP_VERSION}" --product-file-id=\${FILEID}

# CF CLI
FILEID=\$(pivnet product-files -p app-service-adapter -r ${TAS_ADAPTER_VERSION} --format json | jq -r '.[] | select (.name | contains("CF CLI")) | .id')
pivnet download-product-files --product-slug='app-service-adapter' --release-version="${TAS_ADAPTER_VERSION}" --product-file-id=\${FILEID}

# Services Toolkit for VMware Tanzu kubectl-scp
pivnet download-product-files --product-slug='scp-toolkit' --release-version='0.10.0' --product-file-id=1478274

echo "***TAP assets downloaded!***"

### kubectl
pushd \${TMPDIR}
  gunzip -c /mnt/datadisk/tanzu/kubectl-linux-v*.gz > ./kubectl
  install ./kubectl /usr/local/bin/
popd
echo "***kubectl installed!***"

### Helm
pushd \${TMPDIR}
  curl -L https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz -o helm.tgz
  tar zxvf helm.tgz linux-amd64/
  install linux-amd64/helm /usr/local/bin/helm
popd
echo "***Helm installed!***"

### Kustomize
pushd \${TMPDIR}
  curl -L "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" -o kustomize.tgz
  tar zxvf kustomize.tgz
  install ./kustomize /usr/local/bin/
popd
echo "***Kustomize installed!***"

### mc (Minio client CLI)
pushd \${TMPDIR}
  curl -L https://dl.minio.io/client/mc/release/linux-amd64/mc -o ./mc
  install ./mc /usr/local/bin/
popd
echo "***mc installed!***"

### Bitnami Minio Helm Chart and Container image
pushd /mnt/datadisk/helm
  helm pull oci://registry-1.docker.io/bitnamicharts/minio --untar
  cd minio
  mkdir .imgpkg
  helm template minio . --set volumePermissions.enabled=true | kbld -f - --imgpkg-lock-output .imgpkg/images.yml
  export CHART_VERSION=\$(yq .version Chart.yaml)
  export IMGPKG_REGISTRY_HOSTNAME_0="*.docker.io"
  export IMGPKG_REGISTRY_USERNAME_0="${DOCKERHUB_USERNAME}"
  export IMGPKG_REGISTRY_PASSWORD_0="${DOCKERHUB_PASSWORD}"
  imgpkg push -b ${DOCKERHUB_USERNAME}/bitnami-minio-chart-bundle:\${CHART_VERSION} -f .
  imgpkg copy -b ${DOCKERHUB_USERNAME}/bitnami-minio-chart-bundle:\${CHART_VERSION} --to-tar ../bitnami-minio-chart-bundle_\${CHART_VERSION}.tar
  cd ..
  rm -rf minio
popd
echo "***Bitnami Minio downloaded!***"

### Bitnami PostgreSQL Helm Chart and Container image
pushd /mnt/datadisk/helm
  helm pull oci://registry-1.docker.io/bitnamicharts/postgresql --untar
  cd postgresql
  mkdir .imgpkg
  helm template postgresql . --set volumePermissions.enabled=true --set metrics.enabled=true --set auth.database=foo | kbld -f - --imgpkg-lock-output .imgpkg/images.yml
  export CHART_VERSION=\$(yq .version Chart.yaml)
  export IMGPKG_REGISTRY_HOSTNAME_0="*.docker.io"
  export IMGPKG_REGISTRY_USERNAME_0="${DOCKERHUB_USERNAME}"
  export IMGPKG_REGISTRY_PASSWORD_0="${DOCKERHUB_PASSWORD}"
  imgpkg push -b ${DOCKERHUB_USERNAME}/bitnami-postgresql-chart-bundle:\${CHART_VERSION} -f .
  imgpkg copy -b ${DOCKERHUB_USERNAME}/bitnami-postgresql-chart-bundle:\${CHART_VERSION} --to-tar ../bitnami-postgresql-chart-bundle_\${CHART_VERSION}.tar
  cd ..
  rm -rf postgresql
popd
echo "***Bitnami PostgreSQL downloaded!***"

### Bitnami PostgreSQL HA Helm Chart and Container image
pushd /mnt/datadisk/helm
  helm pull oci://registry-1.docker.io/bitnamicharts/postgresql-ha --untar
  cd postgresql-ha
  mkdir .imgpkg
  helm template postgresql-ha . --set pgpool.tls.enabled=true --set pgpool.tls.autoGenerated=foo --set postgresql.tls.enabled=true --set postgresql.tls.certFilename=foo --set postgresql.tls.certKeyFilename=foo --set postgresql.tls.certificatesSecret=foo --set volumePermissions.enabled=true --set metrics.enabled=true | kbld -f - --imgpkg-lock-output .imgpkg/images.yml
  export CHART_VERSION=\$(yq .version Chart.yaml)
  export IMGPKG_REGISTRY_HOSTNAME_0="*.docker.io"
  export IMGPKG_REGISTRY_USERNAME_0="${DOCKERHUB_USERNAME}"
  export IMGPKG_REGISTRY_PASSWORD_0="${DOCKERHUB_PASSWORD}"
  imgpkg push -b ${DOCKERHUB_USERNAME}/bitnami-postgresql-ha-chart-bundle:\${CHART_VERSION} -f .
  imgpkg copy -b ${DOCKERHUB_USERNAME}/bitnami-postgresql-ha-chart-bundle:\${CHART_VERSION} --to-tar ../bitnami-postgresql-ha-chart-bundle_\${CHART_VERSION}.tar
  cd ..
  rm -rf postgresql-ha
popd
echo "***Bitnami PostgreSQL HA downloaded!***"

### Bitnami Redis Helm Chart and Container image
pushd /mnt/datadisk/helm
  helm pull oci://registry-1.docker.io/bitnamicharts/redis --untar
  cd redis
  mkdir .imgpkg
  helm template redis . --set metrics.enabled=true --set sysctl.enabled=true --set sentinel.enabled=true --set volumePermissions.enabled=true | kbld -f - --imgpkg-lock-output .imgpkg/images.yml
  export CHART_VERSION=\$(yq .version Chart.yaml)
  export IMGPKG_REGISTRY_HOSTNAME_0="*.docker.io"
  export IMGPKG_REGISTRY_USERNAME_0="${DOCKERHUB_USERNAME}"
  export IMGPKG_REGISTRY_PASSWORD_0="${DOCKERHUB_PASSWORD}"
  imgpkg push -b ${DOCKERHUB_USERNAME}/bitnami-redis-chart-bundle:\${CHART_VERSION} -f .
  imgpkg copy -b ${DOCKERHUB_USERNAME}/bitnami-redis-chart-bundle:\${CHART_VERSION} --to-tar ../bitnami-redis-chart-bundle_\${CHART_VERSION}.tar
  cd ..
  rm -rf redis
popd
echo "***Bitnami Redis downloaded!***"

### Bitnami Nginx Helm Chart and Container image
pushd /mnt/datadisk/helm
  helm pull oci://registry-1.docker.io/bitnamicharts/nginx --untar
  cd nginx
  mkdir .imgpkg
  helm template nginx . --set cloneStaticSiteFromGit.enabled=true --set metrics.enabled=true --set cloneStaticSiteFromGit.repository="https://github.com/kenojiri/pvtl.cc.git" --set cloneStaticSiteFromGit.branch="main" | kbld -f - --imgpkg-lock-output .imgpkg/images.yml
  export CHART_VERSION=\$(yq .version Chart.yaml)
  export IMGPKG_REGISTRY_HOSTNAME_0="*.docker.io"
  export IMGPKG_REGISTRY_USERNAME_0="${DOCKERHUB_USERNAME}"
  export IMGPKG_REGISTRY_PASSWORD_0="${DOCKERHUB_PASSWORD}"
  imgpkg push -b ${DOCKERHUB_USERNAME}/bitnami-nginx-chart-bundle:\${CHART_VERSION} -f .
  imgpkg copy -b ${DOCKERHUB_USERNAME}/bitnami-nginx-chart-bundle:\${CHART_VERSION} --to-tar ../bitnami-nginx-chart-bundle_\${CHART_VERSION}.tar
  cd ..
  rm -rf nginx
popd
echo "***Bitnami Nginx downloaded!***"

### Bitnami ArgoCD Helm Chart and Container image
pushd /mnt/datadisk/helm
  helm pull oci://registry-1.docker.io/bitnamicharts/argo-cd --untar
  cd argo-cd
  mkdir .imgpkg
  helm template argocd . --set volumePermissions.enabled=true --set redisWait.enabled=true --set dex.enabled=true | kbld -f - --imgpkg-lock-output .imgpkg/images.yml
  export CHART_VERSION=\$(yq .version Chart.yaml)
  export IMGPKG_REGISTRY_HOSTNAME_0="*.docker.io"
  export IMGPKG_REGISTRY_USERNAME_0="${DOCKERHUB_USERNAME}"
  export IMGPKG_REGISTRY_PASSWORD_0="${DOCKERHUB_PASSWORD}"
  imgpkg push -b ${DOCKERHUB_USERNAME}/bitnami-argo-cd-chart-bundle:\${CHART_VERSION} -f .
  imgpkg copy -b ${DOCKERHUB_USERNAME}/bitnami-argo-cd-chart-bundle:\${CHART_VERSION} --to-tar ../bitnami-argo-cd-chart-bundle_\${CHART_VERSION}.tar
  cd ..
  rm -rf argo-cd
popd
echo "***Bitnami ArgoCD downloaded!***"

### Bitnami Gitea Helm Chart and Container image
pushd /mnt/datadisk/helm
  helm pull oci://registry-1.docker.io/bitnamicharts/gitea --untar
  cd gitea
  mkdir .imgpkg
  helm template gitea . --set volumePermissions.enabled=true | kbld -f - --imgpkg-lock-output .imgpkg/images.yml
  export CHART_VERSION=\$(yq .version Chart.yaml)
  export IMGPKG_REGISTRY_HOSTNAME_0="*.docker.io"
  export IMGPKG_REGISTRY_USERNAME_0="${DOCKERHUB_USERNAME}"
  export IMGPKG_REGISTRY_PASSWORD_0="${DOCKERHUB_PASSWORD}"
  imgpkg push -b ${DOCKERHUB_USERNAME}/bitnami-gitea-chart-bundle:\${CHART_VERSION} -f .
  imgpkg copy -b ${DOCKERHUB_USERNAME}/bitnami-gitea-chart-bundle:\${CHART_VERSION} --to-tar ../bitnami-gitea-chart-bundle_\${CHART_VERSION}.tar
  cd ..
  rm -rf gitea
popd
echo "***Bitnami Gitea downloaded!***"

### AVI Multi-Cluster Kubernetes Operator (AMKO) Helm Chart and Container image
pushd /mnt/datadisk/helm
  helm repo add amko https://projects.registry.vmware.com/chartrepo/ako
  helm pull amko/amko --untar
  cd amko
  mkdir .imgpkg
  helm template amko . | kbld -f - --imgpkg-lock-output .imgpkg/images.yml
  export CHART_VERSION=\$(yq .version Chart.yaml)
  export IMGPKG_REGISTRY_HOSTNAME_0="*.docker.io"
  export IMGPKG_REGISTRY_USERNAME_0="${DOCKERHUB_USERNAME}"
  export IMGPKG_REGISTRY_PASSWORD_0="${DOCKERHUB_PASSWORD}"
  imgpkg push -b ${DOCKERHUB_USERNAME}/amko-chart-bundle:\${CHART_VERSION} -f .
  imgpkg copy -b ${DOCKERHUB_USERNAME}/amko-chart-bundle:\${CHART_VERSION} --to-tar ../amko-chart-bundle_\${CHART_VERSION}.tar
  cd ..
  rm -rf amko
popd
echo "***AMKO downloaded!***"

### Grype vulnarability database
curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sh -s -- -b /usr/local/bin
pushd /mnt/datadisk/grype-db
  grype db list -o raw > grype-db-metadata-original.json

  for URL in \$(cat grype-db-metadata-original.json | yq '.available.*[0].url'); do
    curl -sLO \$URL
  done

  echo "available:" > grype-db-metadata.yml
  for ITEM in \$(cat grype-db-metadata-original.json | yq '.available.*[0]' | jq -c .); do
    VERSION=\$(echo \$ITEM | jq .version)
    cat << EOT >> grype-db-metadata.yml
  "\${VERSION}":
  - built: \$(echo \$ITEM | jq .built)
    version: \${VERSION}
    url: https://REPLACE.ME/\$(echo \$ITEM | jq -r .url | awk -F/ '{print \$6}')
    checksum: \$(echo \$ITEM | jq .checksum)
EOT
  done
  cat grype-db-metadata.yml | yq -o json > listing.json
popd
echo "***Grype database downloaded!***"

### TODO: pull some handy Docker images
echo "${DOCKERHUB_PASSWORD}" | docker login -u ${DOCKERHUB_USERNAME} --password-stdin
docker pull busybox:musl
echo "***handy Docker images downloaded!***"

### add lines to ~/.profile
HOMEDIR=\$(getent passwd ${VM_USERNAME} | awk -F: '{print \$6}')
cat <<EOT >> \${HOMEDIR}/.profile
eval "\\\$(direnv hook bash)"
eval "\\\$(kubectl completion bash)"
alias k=kubectl
complete -o default -F __start_kubectl k
EOT
echo "***~/.profile reconfigured!***"

### end of install.sh
EOF
chmod +x script/install.sh

cp ../ubuntu-22.04.2-live-server-packer.json .
mkdir -p export
packer build -on-error=abort \
  -var-file=variables.json \
  ubuntu-22.04.2-live-server-packer.json
cd export
tar cvf ${VM_NAME}.ova \
  ${VM_NAME}.ovf \
  ${VM_NAME}-*.vmdk \
  ${VM_NAME}.mf
