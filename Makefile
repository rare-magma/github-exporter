.PHONY: install
install:
	@mkdir --parents $${HOME}/.local/bin \
	&& mkdir --parents $${HOME}/.config/systemd/user \
	&& cp github_exporter $${HOME}/.local/bin/ \
	&& cp --no-clobber github_exporter.json $${HOME}/.config/github_exporter.json \
	&& chmod 400 $${HOME}/.config/github_exporter.json \
	&& cp github-exporter.timer $${HOME}/.config/systemd/user/ \
	&& cp github-exporter.service $${HOME}/.config/systemd/user/ \
	&& systemctl --user enable --now github-exporter.timer

.PHONY: uninstall
uninstall:
	@rm -f $${HOME}/.local/bin/github_exporter \
	&& rm -f $${HOME}/.config/github_exporter.json \
	&& systemctl --user disable --now github-exporter.timer \
	&& rm -f $${HOME}/.config/.config/systemd/user/github-exporter.timer \
	&& rm -f $${HOME}/.config/systemd/user/github-exporter.service

.PHONY: build
build:
	@go build -ldflags="-s -w" -o github_exporter main.go