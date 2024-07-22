
The following is done for you in the top directory `Makefile`.  Bundled `ds-collector.*.tar.gz` tarballs should already contain multiple `collect-info` binaries to cover your architecture.  The following instructions are normally not required.


## Compile rust binaries for Linux amd64 and arm64

	docker run -v $PWD:/volume -w /volume -t clux/muslrust rustc --target x86_64-unknown-linux-musl *.rs


On Mac aarch:

    docker run --platform linux/arm64 -v $PWD:/volume -w /volume -t clux/muslrust rustc --target aarch64-unknown-linux-musl *.rs

    mv collect-info ../collect-info.aarch64-unknown-linux-musl

    docker run --platform linux/amd64 -v $PWD:/volume -w /volume -t clux/muslrust rustc --target x86_64-unknown-linux-musl *.rs

    mv collect-info ../collect-info.x86_64-unknown-linux-musl


On Linux (or old Mac):

    sudo apt-get install -y qemu binfmt-support qemu-user-static

    docker run --platform linux/arm64 -v /usr/bin/qemu-aarch64-static:/usr/bin/qemu-aarch64-static -v $PWD:/volume -w /volume -t clux/muslrust rustc --target aarch64-unknown-linux-musl *.rs

    mv ../collect-info collect-info.aarch64-unknown-linux-musl

    docker run --platform linux/amd64 -v $PWD:/volume -w /volume -t clux/muslrust rustc --target x86_64-unknown-linux-musl *.rs

    mv collect-info ../collect-info.x86_64-unknown-linux-musl


On Mac aarch, to run integration tests on same Mac aarch:

    rustc *.rs

    mv collect-info ../collect-info.aarch64-apple-darwin