FROM docker.io/buildpack-deps:noble AS build-ffmpeg
	ARG FFMPEG_VERSION=8.1.3
	ARG NV_CODEC_HEADERS_VERSION=n13.0.19.0

	ADD tools/linux/install-ffmpeg-dependencies /

	RUN apt-get update && /install-ffmpeg-dependencies

	RUN git clone --depth 1 --branch ${NV_CODEC_HEADERS_VERSION} https://github.com/FFmpeg/nv-codec-headers.git /tmp/nv-codec-headers && \
		make -C /tmp/nv-codec-headers install PREFIX=/usr/local

	RUN curl -fsSL https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz | tar -xJ -C /tmp && \
		mv /tmp/ffmpeg-${FFMPEG_VERSION} /tmp/ffmpeg

	WORKDIR /tmp/ffmpeg

	RUN ./configure \
		--prefix=/usr/local \
		--enable-shared \
		--disable-static \
		--disable-doc \
		--disable-debug \
		--enable-gpl \
		--enable-version3 \
		--enable-libx264 \
		--enable-libx265 \
		--enable-ffnvcodec \
		--enable-cuda \
		--enable-cuvid \
		--enable-nvenc \
		--enable-nvdec \
		--enable-vaapi \
		--enable-libdrm \
		--enable-libvpl \
		--enable-libmp3lame \
		--enable-libopus \
		--enable-libvorbis \
		--enable-libvpx \
		--enable-libdav1d \
		--enable-libfreetype \
		--enable-libfontconfig \
		--enable-libfribidi \
		--enable-libharfbuzz \
		--enable-libass \
		--enable-gnutls \
		--enable-libsrt \
		--enable-libzimg \
		--enable-libsoxr \
		--enable-libxml2 \
		|| (tail -n 50 ffbuild/config.log; exit 1)

	RUN make -j"$(nproc)" && make install DESTDIR=/ffmpeg-install

	RUN for enc in libx264 libx265 h264_nvenc hevc_nvenc h264_vaapi hevc_vaapi h264_qsv hevc_qsv; do \
			LD_LIBRARY_PATH=/ffmpeg-install/usr/local/lib /ffmpeg-install/usr/local/bin/ffmpeg -hide_banner -h encoder=$enc | head -1 | grep -q "^Encoder $enc" \
				|| { echo "missing encoder: $enc"; exit 1; }; \
		done

FROM docker.io/buildpack-deps:noble AS build-casparcg
	ADD tools/linux/install-dependencies /
	ADD tools/linux/install-ffmpeg-dependencies /

	RUN apt-get update && /install-dependencies && /install-ffmpeg-dependencies

	COPY --from=build-ffmpeg /ffmpeg-install/usr/local /usr/local
	RUN ldconfig

	RUN mkdir /source && mkdir /build && mkdir /install

	WORKDIR /build

	RUN wget https://sdk.lunarg.com/sdk/download/1.4.328.1/linux/vulkansdk-linux-x86_64-1.4.328.1.tar.xz
	RUN tar -xf vulkansdk-linux-x86_64-1.4.328.1.tar.xz && \
		mv 1.4.328.1 /tmp/vulkan-sdk
	ENV VULKAN_SDK=/tmp/vulkan-sdk/x86_64
	ENV PATH=$VULKAN_SDK/bin:$PATH

	COPY ./src /source

	ARG CC
	ARG CXX
	ARG GIT_HASH

	RUN cmake -GNinja /source -DUSE_STATIC_BOOST=ON -DUSE_SYSTEM_CEF=OFF -DENABLE_VULKAN=ON

	RUN cmake --build .

	RUN cmake --install . --prefix staging

	# Find a better way to copy deps
	RUN ln -s /build/staging /staging && \
		/source/shell/copy_deps.sh /build/shell/casparcg /staging/lib

FROM docker.io/ubuntu:noble
	COPY --from=build-casparcg /staging /opt/casparcg

	RUN set -ex; \
			apt-get update; \
			DEBIAN_FRONTEND="noninteractive" apt-get install -y --no-install-recommends \
			tzdata \
			libc++1 \
			libnss3 \
			fontconfig \
			libglvnd0 \
			libgl1 \
			libglx0 \
			libegl1 \
			libgles2 \
                        telnet \
			; \
			rm -rf /var/lib/apt/lists/*

	WORKDIR /opt/casparcg
	RUN chmod 755 run.sh
	ADD tools/linux/run_docker.sh ./

	# Lets the NVIDIA container runtime (docker run --gpus all) mount the
	# driver's NVENC/NVDEC/CUDA libraries alongside OpenGL.
	ENV NVIDIA_VISIBLE_DEVICES=all
	ENV NVIDIA_DRIVER_CAPABILITIES=compute,video,graphics,utility

	CMD ["./run_docker.sh"]
