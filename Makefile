.PHONY: install
install:
	@mkdir --parents $${HOME}/.local/bin \
	&& mkdir --parents $${HOME}/.config/systemd/user \
	&& cp github_exporter.sh $${HOME}/.local/bin/ \
	&& chmod +x $${HOME}/.local/bin/github_exporter.sh \
	&& cp --no-clobber github_exporter.conf $${HOME}/.config/github_exporter.conf \
	&& chmod 400 $${HOME}/.config/github_exporter.conf \
	&& cp github-exporter.timer $${HOME}/.config/systemd/user/ \
	&& cp github-exporter.service $${HOME}/.config/systemd/user/ \
	&& systemctl --user enable --now github-exporter.timer

.PHONY: uninstall
uninstall:
	@rm -f $${HOME}/.local/bin/github_exporter.sh \
	&& rm -f $${HOME}/.config/github_exporter.conf \
	&& systemctl --user disable --now github-exporter.timer \
	&& rm -f $${HOME}/.config/.config/systemd/user/github-exporter.timer \
	&& rm -f $${HOME}/.config/systemd/user/github-exporter.service
