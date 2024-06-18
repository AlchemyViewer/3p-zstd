#!/usr/bin/env bash

cd "$(dirname "$0")"

# turn on verbose debugging output for parabuild logs.
exec 4>&1; export BASH_XTRACEFD=4; set -x
# make errors fatal
set -e
# complain about unset env variables
set -u

if [ -z "$AUTOBUILD" ] ; then 
    exit 1
fi

if [[ "$OSTYPE" == "cygwin" || "$OSTYPE" == "msys" ]] ; then
    autobuild="$(cygpath -u $AUTOBUILD)"
else
    autobuild="$AUTOBUILD"
fi

top="$(pwd)"
stage="$(pwd)/stage"

mkdir -p $stage

# Load autobuild provided shell functions and variables
source_environment_tempfile="$stage/source_environment.sh"
"$autobuild" source_environment > "$source_environment_tempfile"
. "$source_environment_tempfile"

ZSTD_SOURCE_DIR="zstd"

# Create the staging folders
mkdir -p "$stage/LICENSES"

echo "1.5.6" > "${stage}/VERSION.txt"

pushd "$ZSTD_SOURCE_DIR/build/cmake"
    case "$AUTOBUILD_PLATFORM" in

        # ------------------------ windows, windows64 ------------------------
        windows*)
            load_vsvars

            mkdir -p "$stage/lib"/{debug,release}

            mkdir -p "build_debug"
            pushd "build_debug"
                cmake .. -G Ninja \
                            -DCMAKE_BUILD_TYPE="Debug" \
                            -DCMAKE_INSTALL_PREFIX="$(cygpath -w "$stage")" \
                            -DCMAKE_INSTALL_LIBDIR="$(cygpath -w "$stage/lib/debug")" \
                            -DZSTD_BUILD_SHARED=OFF \
                            -DZSTD_BUILD_PROGRAMS=OFF
            
                cmake --build . --config Debug --clean-first --target install
            popd

            mkdir -p "build_release"
            pushd "build_release"
                cmake .. -G Ninja \
                            -DCMAKE_BUILD_TYPE="Release" \
                            -DCMAKE_INSTALL_PREFIX="$(cygpath -w "$stage")" \
                            -DCMAKE_INSTALL_LIBDIR="$(cygpath -w "$stage/lib/release")" \
                            -DZSTD_BUILD_SHARED=OFF \
                            -DZSTD_BUILD_PROGRAMS=OFF
            
                cmake --build . --config Release --clean-first --target install
            popd
        ;;
        darwin*)
            # Setup build flags
            C_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_CFLAGS"
            C_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_CFLAGS"
            CXX_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_CXXFLAGS"
            CXX_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_CXXFLAGS"
            LINK_OPTS_X86="-arch x86_64 $LL_BUILD_RELEASE_LINKER"
            LINK_OPTS_ARM64="-arch arm64 $LL_BUILD_RELEASE_LINKER"

            # deploy target
            export MACOSX_DEPLOYMENT_TARGET=${LL_BUILD_DARWIN_BASE_DEPLOY_TARGET}

            mkdir -p "build_release_x86"
            pushd "build_release_x86"
                CFLAGS="$C_OPTS_X86" \
                CXXFLAGS="$CXX_OPTS_X86" \
                LDFLAGS="$LINK_OPTS_X86" \
                cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_C_FLAGS="$C_OPTS_X86" \
                    -DCMAKE_CXX_FLAGS="$CXX_OPTS_X86" \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                    -DCMAKE_OSX_ARCHITECTURES="x86_64" \
                    -DCMAKE_MACOSX_RPATH=YES \
                    -DCMAKE_INSTALL_PREFIX="$stage/release_x86" \
                    -DZSTD_BUILD_SHARED=OFF \
                    -DZSTD_BUILD_PROGRAMS=OFF 

                cmake --build . --config Release --clean-first --target install

                # conditionally run unit tests
                #if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                #    ctest -C Release
                #fi
            popd

            mkdir -p "build_release_arm64"
            pushd "build_release_arm64"
                CFLAGS="$C_OPTS_ARM64" \
                CXXFLAGS="$CXX_OPTS_ARM64" \
                LDFLAGS="$LINK_OPTS_ARM64" \
                cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS:BOOL=OFF \
                    -DCMAKE_C_FLAGS="$C_OPTS_ARM64" \
                    -DCMAKE_CXX_FLAGS="$CXX_OPTS_ARM64" \
                    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET} \
                    -DCMAKE_OSX_ARCHITECTURES="arm64" \
                    -DCMAKE_MACOSX_RPATH=YES \
                    -DCMAKE_INSTALL_PREFIX="$stage/release_arm64" \
                    -DZSTD_BUILD_SHARED=OFF \
                    -DZSTD_BUILD_PROGRAMS=OFF 

                cmake --build . --config Release --clean-first --target install

                # conditionally run unit tests
                #if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                #    ctest -C Release
                #fi
            popd

            # prepare staging dirs
            mkdir -p "$stage/include/"
            mkdir -p "$stage/lib/release"

            # create fat libraries
            lipo -create ${stage}/release_x86/lib/libzstd.a ${stage}/release_arm64/lib/libzstd.a -output ${stage}/lib/release/libzstd.a

            # copy headers
            mv $stage/release_x86/include/* $stage/include/
        ;;
        linux*)
            # Linux build environment at Linden comes pre-polluted with stuff that can
            # seriously damage 3rd-party builds.  Environmental garbage you can expect
            # includes:
            #
            #    DISTCC_POTENTIAL_HOSTS     arch           root        CXXFLAGS
            #    DISTCC_LOCATION            top            branch      CC
            #    DISTCC_HOSTS               build_name     suffix      CXX
            #    LSDISTCC_ARGS              repo           prefix      CFLAGS
            #    cxx_version                AUTOBUILD      SIGN        CPPFLAGS
            #
            # So, clear out bits that shouldn't affect our configure-directed build
            # but which do nonetheless.
            #
            unset DISTCC_HOSTS CFLAGS CPPFLAGS CXXFLAGS

            # Default target per --address-size
            opts_c="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE_CFLAGS}"
            opts_cxx="${TARGET_OPTS:--m$AUTOBUILD_ADDRSIZE $LL_BUILD_RELEASE_CXXFLAGS}"
 
            # Handle any deliberate platform targeting
            if [ -z "${TARGET_CPPFLAGS:-}" ]; then
                # Remove sysroot contamination from build environment
                unset CPPFLAGS
            else
                # Incorporate special pre-processing flags
                export CPPFLAGS="$TARGET_CPPFLAGS"
            fi

            # Release
            mkdir -p "build_release"
            pushd "build_release"
                CFLAGS="$opts_c" \
                CXXFLAGS="$opts_cxx" \
                    cmake ../ -G"Ninja" \
                        -DCMAKE_BUILD_TYPE=Release \
                        -DCMAKE_C_FLAGS="$opts_c" \
                        -DCMAKE_CXX_FLAGS="$opts_cxx" \
                        -DCMAKE_INSTALL_PREFIX="$stage" \
                        -DZSTD_BUILD_SHARED=OFF \
                        -DZSTD_BUILD_PROGRAMS=OFF

                cmake --build . --config Release --parallel $AUTOBUILD_CPU_COUNT

                # conditionally run unit tests
                if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                    ctest -C Release
                fi

                cmake --install . --config Release
            popd
        ;;
    esac
popd

mkdir -p "$stage/LICENSES"
cp ${ZSTD_SOURCE_DIR}/LICENSE "$stage/LICENSES/zstd.txt"
