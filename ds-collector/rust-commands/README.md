## Compile rust binaries for Linux

	docker run -v $PWD:/volume -w /volume -t clux/muslrust rustc --target x86_64-unknown-linux-musl *.rs

