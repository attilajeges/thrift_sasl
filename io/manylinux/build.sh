#!/bin/bash
# Copyright 2015 Cloudera Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -eu -o pipefail
set -x

# Called inside the manylinux1 image
echo "Started $0 $@"

PIP_DISTS_BUILD_DIR="$1"
GIT_VERSION_TAG="$2"
GITHUB_ACCOUNT="$3"

PKG_NAME="thrift_sasl"
GIT_REPO="thrift_sasl"
GIT_URL="https://github.com/${GITHUB_ACCOUNT}/${GIT_REPO}.git"

WHEELHOUSE_DIR="${PIP_DISTS_BUILD_DIR}/wheelhouse"
SDIST_DIR="${PIP_DISTS_BUILD_DIR}/sdist"

# cyrus-sasl & cyrus-sasl-devel are required by sasl package
SYSTEM_REQUIREMENTS=(cyrus-sasl cyrus-sasl-devel krb5-libs krb5-devel)

prepare_system() {
  # Install system packages required by sasl
  yum install -y "${SYSTEM_REQUIREMENTS[@]}"

  cd /tmp
  git clone -b "$GIT_VERSION_TAG" --single-branch "$GIT_URL"
  cd "$GIT_REPO"
  echo "Build directory: $(pwd)"

  # Clean up dists directory
  rm -rf "$PIP_DISTS_BUILD_DIR" || true
  mkdir -p "$PIP_DISTS_BUILD_DIR"

  echo "Python versions found: $(cd /opt/python && echo cp* | sed -e 's|[^ ]*-||g')"
  g++ --version
}

is_cpython2() {
  local pyver_abi="$1"
  [[ "$pyver_abi" =~ ^cp2 ]]
}

build_wheel() {
  local pydir=""
  local wheel_path=""
  for pydir in /opt/python/*; do
    # Build universal wheel with python3
    local pyver_abi="$(basename $pydir)"
    if is_cpython2 "$pyver_abi"; then continue; fi

    echo "Building universal wheel with $(${pydir}/bin/python -V 2>&1)"
    "${pydir}/bin/python" setup.py bdist_wheel --universal -d "$WHEELHOUSE_DIR"
    wheel_path="$(ls ${WHEELHOUSE_DIR}/*.whl)"
    break
  done

  if [ -z "wheel_path" ]; then
    echo "Failed building wheels. Couldn't find python>=3.0"
    exit 1
  fi
}

show_wheel() {
  ls -l "${WHEELHOUSE_DIR}/"*.whl
}

build_sdist() {
  local pydir=""
  local sdist_path=""
  for pydir in /opt/python/*; do
    # Build sdist with python3
    local pyver_abi="$(basename $pydir)"
    if is_cpython2 "$pyver_abi"; then continue; fi

    echo "Building sdist with $(${pydir}/bin/python -V 2>&1)"
    "${pydir}/bin/python" setup.py sdist -d "$SDIST_DIR"
    sdist_path="$(ls ${SDIST_DIR}/*.tar.gz)"
    break
  done

  if [ -z "$sdist_path" ]; then
    echo "Failed building sdist. Couldn't find python>=3.0"
    exit 1
  fi
}

show_sdist() {
  ls -l "$SDIST_DIR"
}

set_up_virt_env() {
  local pydir="$1"
  local pyver_abi="$(basename $pydir)"

  if is_cpython2 "$pyver_abi"; then
    "${pydir}/bin/python" -m virtualenv thrift_sasl_test_env
  else
    "${pydir}/bin/python" -m venv thrift_sasl_test_env
  fi

  # set -eu must be disabled temporarily for activating the env.
  set +e +u
  source thrift_sasl_test_env/bin/activate
  set -eu
}

tear_down_virt_env() {
  # set -eu must be disabled temporarily for deactivating the env.
  set +e +u
  deactivate
  set -eu

  rm -rf thrift_sasl_test_env
}

sanity_check() {
  cat <<EOF >/tmp/sanity_check.py
from thrift_sasl import TSaslClientTransport
EOF

  cd /tmp

  # Install sdist with different python versions and run sanity_check.
  local sdistfn="$(ls ${SDIST_DIR}/${PKG_NAME}-*.tar.gz)"
  local pydir=""
  for pydir in /opt/python/*; do
    set_up_virt_env "$pydir"
    pip install --upgrade --force-reinstall --no-binary "$PKG_NAME" "$sdistfn"
    python /tmp/sanity_check.py
    tear_down_virt_env
  done

  # Install universal wheel with different python versions and run sanity_check.
  local whlfn="$(ls ${WHEELHOUSE_DIR}/${PKG_NAME}-*-py2.py3-none-any.whl)"
  for pydir in /opt/python/*; do
    set_up_virt_env "$pydir"
    pip install --upgrade --force-reinstall --only-binary "$PKG_NAME" "$whlfn"
    python /tmp/sanity_check.py
    tear_down_virt_env
  done
}

prepare_system

build_wheel
show_wheel

build_sdist
show_sdist

sanity_check
