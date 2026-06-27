package docker

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	"emperror.dev/errors"
	"github.com/apex/log"
	"github.com/buger/jsonparser"
	"github.com/docker/docker/api/types"
	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/mount"
	"github.com/docker/docker/client"
	"github.com/pterodactyl/wings/config"
	"github.com/pterodactyl/wings/environment"
	"github.com/pterodactyl/wings/system"
)

var ErrNotAttached = errors.Sentinel("not attached to instance")

type noopWriter struct{}

var _ io.Writer = noopWriter{}

func (nw noopWriter) Write(b []byte) (int, error) {
	return len(b), nil
}

func (e *Environment) Attach(ctx context.Context) error {
	if e.IsAttached() {
		return nil
	}

	opts := types.ContainerAttachOptions{
		Stdin:  true,
		Stdout: true,
		Stderr: true,
		Stream: true,
	}

	if st, err := e.client.ContainerAttach(ctx, e.Id, opts); err != nil {
		return errors.WrapIf(err, "environment/docker: error while attaching to container")
	} else {
		e.SetStream(&st)
	}

	go func() {
		pollCtx, cancel := context.WithCancel(context.Background())
		defer cancel()
		defer e.stream.Close()
		defer func() {
			e.SetState(environment.ProcessOfflineState)
			e.SetStream(nil)
		}()

		go func() {
			if err := e.pollResources(pollCtx); err != nil {
				if !errors.Is(err, context.Canceled) {
					e.log().WithField("error", err).Error("error during environment resource polling")
				} else {
					e.log().Warn("stopping server resource polling: context canceled")
				}
			}
		}()

		if err := system.ScanReader(e.stream.Reader, func(v []byte) {
			e.logCallbackMx.Lock()
			defer e.logCallbackMx.Unlock()
			e.logCallback(v)
		}); err != nil && err != io.EOF {
			log.WithField("error", err).WithField("container_id", e.Id).Warn("error processing scanner line in console output")
			return
		}
	}()

	return nil
}

func (e *Environment) InSituUpdate() error {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second*10)
	defer cancel()

	if _, err := e.ContainerInspect(ctx); err != nil {
		if client.IsErrNotFound(err) {
			return nil
		}
		return errors.Wrap(err, "environment/docker: could not inspect container")
	}

	if _, err := e.client.ContainerUpdate(ctx, e.Id, container.UpdateConfig{
		Resources: e.Configuration.Limits().AsContainerResources(),
	}); err != nil {
		return errors.Wrap(err, "environment/docker: could not update container")
	}
	return nil
}

func (e *Environment) Create() error {
	ctx := context.Background()

	if _, err := e.ContainerInspect(ctx); err == nil {
		return nil
	} else if !client.IsErrNotFound(err) {
		return errors.WrapIf(err, "environment/docker: failed to inspect container")
	}

	if err := e.ensureImageExists(e.meta.Image); err != nil {
		return errors.WithStackIf(err)
	}

	cfg := config.Get()
	a := e.Configuration.Allocations()
	evs := e.Configuration.EnvironmentVariables()
	for i, v := range evs {
		if v == "SERVER_IP=127.0.0.1" {
			evs[i] = "SERVER_IP=" + cfg.Docker.Network.Interface
		}
	}

	confLabels := e.Configuration.Labels()
	labels := make(map[string]string, 2+len(confLabels))

	for key := range confLabels {
		labels[key] = confLabels[key]
	}
	labels["Service"] = "Pterodactyl"
	labels["ContainerType"] = "server_process"

	conf := &container.Config{
		Hostname:     e.Id,
		Domainname:   cfg.Docker.Domainname,
		AttachStdin:  true,
		AttachStdout: true,
		AttachStderr: true,
		OpenStdin:    true,
		Tty:          true,
		ExposedPorts: a.Exposed(),
		Image:        strings.TrimPrefix(e.meta.Image, "~"),
		Env:          e.Configuration.EnvironmentVariables(),
		Labels:       labels,
	}

	if cfg.System.User.Rootless.Enabled {
		conf.User = fmt.Sprintf("%d:%d", cfg.System.User.Rootless.ContainerUID, cfg.System.User.Rootless.ContainerGID)
	} else {
		conf.User = strconv.Itoa(cfg.System.User.Uid) + ":" + strconv.Itoa(cfg.System.User.Gid)
	}

	networkMode := container.NetworkMode(cfg.Docker.Network.Mode)
	if a.ForceOutgoingIP {
		e.log().Debug("environment/docker: forcing outgoing IP address")
		networkName := "ip-" + strings.ReplaceAll(strings.ReplaceAll(a.DefaultMapping.Ip, ".", "-"), ":", "-")
		networkMode = container.NetworkMode(networkName)

		if _, err := e.client.NetworkInspect(ctx, networkName, types.NetworkInspectOptions{}); err != nil {
			if !client.IsErrNotFound(err) {
				return err
			}

			if _, err := e.client.NetworkCreate(ctx, networkName, types.NetworkCreate{
				Driver:     "bridge",
				EnableIPv6: false,
				Internal:   false,
				Attachable: false,
				Ingress:    false,
				ConfigOnly: false,
				Options: map[string]string{
					"encryption": "false",
					"com.docker.network.bridge.default_bridge": "false",
					"com.docker.network.host_ipv4":             a.DefaultMapping.Ip,
				},
			}); err != nil {
				return err
			}
		}
	}

	hostConf := &container.HostConfig{
		PortBindings: a.DockerBindings(),
		Mounts:       e.convertMounts(),
		Tmpfs: map[string]string{
			"/tmp": "rw,exec,nosuid,size=" + strconv.Itoa(int(cfg.Docker.TmpfsSize)) + "M",
		},
		Resources:      e.Configuration.Limits().AsContainerResources(),
		DNS:            cfg.Docker.Network.Dns,
		LogConfig:      cfg.Docker.ContainerLogConfig(),
		Devices:        hostDevices(),
		SecurityOpt:    []string{"no-new-privileges"},
		ReadonlyRootfs: true,
		CapDrop: []string{
			"setpcap", "mknod", "audit_write", "net_raw", "dac_override",
			"fowner", "fsetid", "net_bind_service", "sys_chroot", "setfcap",
		},
		NetworkMode: networkMode,
		UsernsMode:  container.UsernsMode(cfg.Docker.UsernsMode),
	}

	if _, err := e.client.ContainerCreate(ctx, conf, hostConf, nil, nil, e.Id); err != nil {
		return errors.Wrap(err, "environment/docker: failed to create container")
	}

	return nil
}

func hostDevices() []container.DeviceMapping {
	var devices []container.DeviceMapping
	for _, path := range []string{"/dev/kvm"} {
		if _, err := os.Stat(path); err == nil {
			devices = append(devices, container.DeviceMapping{
				PathOnHost:        path,
				PathInContainer:   path,
				CgroupPermissions: "rwm",
			})
		}
	}
	return devices
}

func (e *Environment) Destroy() error {
	e.SetState(environment.ProcessStoppingState)

	err := e.client.ContainerRemove(context.Background(), e.Id, types.ContainerRemoveOptions{
		RemoveVolumes: true,
		RemoveLinks:   false,
		Force:         true,
	})

	e.SetState(environment.ProcessOfflineState)

	if err != nil && client.IsErrNotFound(err) {
		return nil
	}

	return err
}

func (e *Environment) SendCommand(c string) error {
	if !e.IsAttached() {
		return errors.Wrap(ErrNotAttached, "environment/docker: cannot send command to container")
	}

	e.mu.RLock()
	defer e.mu.RUnlock()

	if e.meta.Stop.Type == "command" && c == e.meta.Stop.Value {
		e.SetState(environment.ProcessStoppingState)
	}

	_, err := e.stream.Conn.Write([]byte(c + "\n"))

	return errors.Wrap(err, "environment/docker: could not write to container stream")
}

func (e *Environment) Readlog(lines int) ([]string, error) {
	r, err := e.client.ContainerLogs(context.Background(), e.Id, types.ContainerLogsOptions{
		ShowStdout: true,
		ShowStderr: true,
		Tail:       strconv.Itoa(lines),
	})
	if err != nil {
		return nil, errors.WithStack(err)
	}
	defer r.Close()

	var out []string
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		out = append(out, scanner.Text())
	}

	return out, nil
}

func (e *Environment) ensureImageExists(image string) error {
	e.Events().Publish(environment.DockerImagePullStarted, "")
	defer e.Events().Publish(environment.DockerImagePullCompleted, "")

	if strings.HasPrefix(image, "~") {
		return nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Minute*15)
	defer cancel()

	var registryAuth *config.RegistryConfiguration
	for registry, c := range config.Get().Docker.Registries {
		if !strings.HasPrefix(image, registry) {
			continue
		}

		log.WithField("registry", registry).Debug("using authentication for registry")
		registryAuth = &c
		break
	}

	imagePullOptions := types.ImagePullOptions{All: false}
	if registryAuth != nil {
		b64, err := registryAuth.Base64()
		if err != nil {
			log.WithError(err).Error("failed to get registry auth credentials")
		}

		imagePullOptions.RegistryAuth = b64
	}

	out, err := e.client.ImagePull(ctx, image, imagePullOptions)
	if err != nil {
		images, ierr := e.client.ImageList(ctx, types.ImageListOptions{})
		if ierr != nil {
			return errors.Wrap(ierr, "environment/docker: failed to list images")
		}

		for _, img := range images {
			for _, t := range img.RepoTags {
				if t != image {
					continue
				}

				log.WithFields(log.Fields{
					"image":        image,
					"container_id": e.Id,
					"err":          err.Error(),
				}).Warn("unable to pull requested image from remote source, however the image exists locally")

				return nil
			}
		}

		return errors.Wrapf(err, "environment/docker: failed to pull \"%s\" image for server", image)
	}
	defer out.Close()

	log.WithField("image", image).Debug("pulling docker image... this could take a bit of time")

	scanner := bufio.NewScanner(out)

	for scanner.Scan() {
		b := scanner.Bytes()
		status, _ := jsonparser.GetString(b, "status")
		progress, _ := jsonparser.GetString(b, "progress")

		e.Events().Publish(environment.DockerImagePullStatus, status+" "+progress)
	}

	if err := scanner.Err(); err != nil {
		return err
	}

	log.WithField("image", image).Debug("completed docker image pull")

	return nil
}

func (e *Environment) convertMounts() []mount.Mount {
	var out []mount.Mount

	for _, m := range e.Configuration.Mounts() {
		out = append(out, mount.Mount{
			Type:     mount.TypeBind,
			Source:   m.Source,
			Target:   m.Target,
			ReadOnly: m.ReadOnly,
		})
	}

	return out
}
