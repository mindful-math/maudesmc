# builds static-ish PIC libmaude.so from maudesmc + cvc5, package tarball
FROM quay.io/pypa/manylinux_2_28_aarch64 AS builder

ENV DEBIAN_FRONTEND=noninteractive
RUN yum install -y \
    git curl wget ca-certificates \
    gcc gcc-c++ make m4 cmake ninja-build \
    autoconf automake libtool bison flex patch \
    xz zlib-devel \
    python3 python3-pip \
    popt-devel \
 && yum clean all

ENV OPTLIB=/opt/maude-deps
WORKDIR /build

# PIC static
RUN curl -fLo libsigsegv-2.15.tar.gz \
      https://ftp.gnu.org/gnu/libsigsegv/libsigsegv-2.15.tar.gz \
 && tar xf libsigsegv-2.15.tar.gz && cd libsigsegv-2.15 && mkdir Opt && cd Opt \
 && ../configure CFLAGS="-O3 -fPIC" --prefix=$OPTLIB --enable-shared=no \
 && make -j$(nproc) && make install && cd /build && rm -rf libsigsegv*

RUN curl -fLo gmp-6.3.0.tar.xz https://gmplib.org/download/gmp/gmp-6.3.0.tar.xz \
 && tar xf gmp-6.3.0.tar.xz && cd gmp-6.3.0 && mkdir Opt && cd Opt \
 && ../configure --prefix=$OPTLIB --enable-cxx --enable-shared=no --with-pic \
      CFLAGS="-O2 -fPIC" CXXFLAGS="-O2 -fPIC" \
 && make -j$(nproc) && make install && cd /build && rm -rf gmp*

RUN curl -fLo mpfr-4.2.1.tar.xz https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.1.tar.xz \
 && tar xf mpfr-4.2.1.tar.xz && cd mpfr-4.2.1 && mkdir Opt && cd Opt \
 && ../configure --prefix=$OPTLIB --with-gmp=$OPTLIB --enable-shared=no \
      CFLAGS="-O2 -fPIC" \
 && make -j$(nproc) && make install && cd /build && rm -rf mpfr*

RUN curl -fLo buddy-2.4.tar.gz \
      https://github.com/utwente-fmt/buddy/releases/download/v2.4/buddy-2.4.tar.gz \
 && tar xf buddy-2.4.tar.gz && cd buddy-2.4 && mkdir Opt && cd Opt \
 && ../configure LDFLAGS=-lm CFLAGS="-O3 -fPIC" CXXFLAGS="-O3 -fPIC" \
      --prefix=$OPTLIB --disable-shared \
 && make -j$(nproc) && make install && cd /build && rm -rf buddy*

RUN curl -fLo libtecla-1.6.3.tar.gz \
      "https://sites.astro.caltech.edu/~mcs/tecla/libtecla-1.6.3.tar.gz" \
 && tar xf libtecla-1.6.3.tar.gz && cd libtecla \
 && curl -fLo config.guess https://raw.githubusercontent.com/gcc-mirror/gcc/master/config.guess \
 && curl -fLo config.sub   https://raw.githubusercontent.com/gcc-mirror/gcc/master/config.sub \
 && chmod +x config.guess config.sub \
 && ./configure CFLAGS="-O3 -fPIC" --prefix=$OPTLIB \
 && make -j$(nproc) && make install && cd /build && rm -rf libtecla*

 # cvc5 uses dataclasses and so we need python311 isntead.
RUN ln -sf /opt/python/cp311-cp311/bin/python3 /usr/local/bin/python3 \
 && ln -sf /opt/python/cp311-cp311/bin/python3 /usr/local/bin/python

# cvc5 – build and install, then promote libpoly to $OPTLIB
RUN git clone --depth=1 https://github.com/cvc5/cvc5.git /build/cvc5 \
 && cd /build/cvc5 \
 && ./configure.sh unrestricted \
      --prefix=$OPTLIB --static --auto-download --poly --no-pyvenv \
      --name=build --dep-path=$OPTLIB \
 && cd build \
 && make -j$(nproc) cvc5 cvc5parser \
 && find . -name 'libcvc5*.a' -o -name 'libpoly*.a' -o -name 'libpicpoly*.a' \
         -o -name 'libpicpolyxx*.a' -o -name 'libcadical*.a' | \
      xargs -I{} cp {} $OPTLIB/lib/ \
 && cp -r /build/cvc5/include/cvc5 $OPTLIB/include/ \
 && find /build/cvc5/build -name 'cvc5_export.h' -exec cp {} $OPTLIB/include/cvc5/ \; \
 && ln -sf $OPTLIB/lib/libpicpoly.a   $OPTLIB/lib/libpoly.a \
 && ln -sf $OPTLIB/lib/libpicpolyxx.a $OPTLIB/lib/libpolyxx.a \
 && ls -la $OPTLIB/lib/libcvc5* $OPTLIB/lib/libpoly* $OPTLIB/lib/libpicpoly* \
 && cd /build && rm -rf cvc5

# maudesmc (copy from build context)
COPY . /build/maudesmc
WORKDIR /build/maudesmc

RUN pip3 install meson tomli pyparsing
RUN find $OPTLIB -type f | sort
RUN ls -la $OPTLIB/lib/libcvc5* $OPTLIB/lib/libpoly* 2>&1
# adj meson options to match my tree (SMT=cvc5, libmaude ON, etc.)
RUN meson setup build \
      --prefix=/usr/local \
      -Dbuildtype=release \
      -Db_staticpic=true \
      -Dcpp_args="-fPIC -O3" \
      -Dc_args="-fPIC -O3" \
      -Dextra-include-dirs=$OPTLIB/include \
      -Dextra-lib-dirs=$OPTLIB/lib \
      -Dstatic-libs=gmp,buddy,sigsegv,cvc5 \
      -Dwith-smt=cvc5 \
      -Dwith-ltsmin=disabled

RUN meson compile -C build \
 && meson install -C build --destdir /tmp/inst

# collect libmaude + config.h
RUN set -e \
 && PKG=/tmp/libmaude-pkg && rm -rf "$PKG" && mkdir -p "$PKG" \
 && echo "=== tree under build/ and /tmp/inst ===" \
 && find /build/maudesmc/build /tmp/inst -name '*maude*' 2>/dev/null | sort | head -80 \
 && echo "=== possible .so files ===" \
 && find /build/maudesmc/build /tmp/inst -type f \( -name '*.so' -o -name '*.so.*' \) 2>/dev/null | sort \
 && echo "=== pick real ELF libmaude ===" \
 && LIB="" \
 && for f in $(find /build/maudesmc/build /tmp/inst -type f \( -name 'libmaude.so' -o -name 'libmaude.so.*' \) 2>/dev/null); do \
      echo "candidate: $f ($(wc -c < "$f") bytes)"; \
      if head -c 4 "$f" | od -An -tx1 | grep -q '7f 45 4c 46'; then \
        echo "  -> ELF, selecting"; \
        LIB="$f"; \
        break; \
      else \
        echo "  -> not ELF, skip"; \
        head -c 80 "$f" | od -c | head -2; \
      fi; \
    done \
 && CONFIG=$(find /build/maudesmc/build /tmp/inst -name config.h 2>/dev/null | head -1) \
 && echo "CONFIG=$CONFIG" \
 && echo "LIB=$LIB" \
 && [ -n "$CONFIG" ] || { echo "config.h not found"; exit 1; } \
 && [ -n "$LIB" ]    || { echo "No ELF libmaude.so found"; exit 1; } \
 && cp -a "$CONFIG" "$PKG/config.h" \
 && cp -a "$LIB" "$PKG/libmaude.so" \
 && cp "$OPTLIB/lib/libcvc5.a" "$PKG/" 2>/dev/null || true \
 && cp -r "$OPTLIB/include/cvc5" "$PKG/cvc5-include" \
 && echo "=== packaged ===" \
 && ls -la "$PKG" \
 && head -c 4 "$PKG/libmaude.so" | od -An -tx1 \
 && tar -C /tmp -cJf /tmp/libmaude.tar.xz libmaude-pkg \
 && ls -lh /tmp/libmaude.tar.xz


FROM quay.io/pypa/manylinux_2_28_aarch64 AS export
COPY --from=builder /tmp/libmaude-pkg /libmaude-pkg
COPY --from=builder /tmp/libmaude.tar.xz /libmaude.tar.xz
CMD ["ls", "-lh", "/libmaude-pkg", "/libmaude.tar.xz"]