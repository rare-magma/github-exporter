package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/google/go-github/v69/github"
)

type Config struct {
	Bucket           string `json:"Bucket"`
	InfluxDBHost     string `json:"InfluxDBHost"`
	InfluxDBApiToken string `json:"InfluxDBApiToken"`
	Org              string `json:"Org"`
	GithubApiToken   string `json:"GithubApiToken"`
}

type retryableTransport struct {
	transport             http.RoundTripper
	TLSHandshakeTimeout   time.Duration
	ResponseHeaderTimeout time.Duration
}

const retryCount = 3
const stringLimit = 1024

func shouldRetry(err error, resp *http.Response) bool {
	if err != nil {
		return true
	}
	if resp == nil {
		return true
	}
	switch resp.StatusCode {
	case http.StatusInternalServerError, http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout, http.StatusTooManyRequests:
		return true
	default:
		return false
	}
}

func (t *retryableTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	var bodyBytes []byte
	if req.Body != nil {
		bodyBytes, _ = io.ReadAll(req.Body)
		req.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
	}
	resp, err := t.transport.RoundTrip(req)
	retries := 0
	for shouldRetry(err, resp) && retries < retryCount {
		backoff := time.Duration(math.Pow(2, float64(retries))) * time.Second
		time.Sleep(backoff)
		if resp != nil && resp.Body != nil {
			io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
		}
		if req.Body != nil {
			req.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))
		}
		if resp != nil && resp.Status != "" {
			log.Printf("Previous request failed with %s", resp.Status)
		}
		log.Printf("Retry %d of request to: %s", retries+1, req.URL)
		resp, err = t.transport.RoundTrip(req)
		retries++
	}
	return resp, err
}

func escapeTagValue(value string) string {
	withoutCommas := strings.ReplaceAll(value, ",", `\,`)
	withoutEquals := strings.ReplaceAll(withoutCommas, "=", `\=`)
	escaped := strings.ReplaceAll(withoutEquals, ` `, `\ `)
	runes := []rune(escaped)
	if len(runes) <= stringLimit {
		return escaped
	}
	return string(runes[0:stringLimit-3]) + "..."
}

func main() {
	confFilePath := "github_exporter.json"
	confData, err := os.Open(confFilePath)
	if err != nil {
		log.Fatalln("Error reading config file: ", err)
	}
	defer confData.Close()
	var config Config
	err = json.NewDecoder(confData).Decode(&config)
	if err != nil {
		log.Fatalln("Error reading configuration: ", err)
	}
	if config.Bucket == "" {
		log.Fatalln("Bucket is required")
	}
	if config.InfluxDBHost == "" {
		log.Fatalln("InfluxDBHost is required")
	}
	if config.InfluxDBApiToken == "" {
		log.Fatalln("InfluxDBApiToken is required")
	}
	if config.Org == "" {
		log.Fatalln("Org is required")
	}
	if config.GithubApiToken == "" {
		log.Fatalln("GithubApiToken is required")
	}

	transport := &retryableTransport{
		transport:             &http.Transport{},
		TLSHandshakeTimeout:   30 * time.Second,
		ResponseHeaderTimeout: 30 * time.Second,
	}
	client := &http.Client{
		Timeout:   30 * time.Second,
		Transport: transport,
	}
	ghc := github.NewClient(client).WithAuthToken(config.GithubApiToken)
	opts := &github.RepositoryListByAuthenticatedUserOptions{Type: "owner"}
	ctx := context.Background()
	repos, resp, err := ghc.Repositories.ListByAuthenticatedUser(context.WithValue(ctx, github.SleepUntilPrimaryRateLimitResetWhenRateLimited, true), opts)
	if _, ok := err.(*github.RateLimitError); ok {
		log.Fatalln("Hit rate limit")
	}
	if _, ok := err.(*github.AbuseRateLimitError); ok {
		log.Fatalln("Hit secondary rate limit")
	}
	if err != nil {
		log.Fatalln("Error getting list of repositories: ", err)
	}
	if resp.StatusCode != http.StatusOK {
		log.Fatalln("Error getting list of repositories: ", resp.Status)
	}
	payload := bytes.Buffer{}
	wg := &sync.WaitGroup{}
	for _, repo := range repos {
		if *repo.Archived || *repo.Fork || *repo.Private || *repo.Disabled {
			continue
		}

		wg.Add(1)
		go func(payload *bytes.Buffer) {
			defer wg.Done()
			clones, _, err := ghc.Repositories.ListTrafficClones(context.WithValue(ctx, github.SleepUntilPrimaryRateLimitResetWhenRateLimited, true), repo.GetOwner().GetLogin(), repo.GetName(), nil)
			if err != nil {
				log.Fatalln("Error getting clones traffic data: ", err)
			}
			for _, value := range clones.Clones {
				influxLine := fmt.Sprintf("github_stats_clones,repo=%s count=%d,uniques=%d %v\n", repo.GetFullName(), *value.Count, *value.Uniques, value.Timestamp.Time.Unix())
				payload.WriteString(influxLine)
			}
		}(&payload)

		wg.Add(1)
		go func(payload *bytes.Buffer) {
			defer wg.Done()
			paths, _, err := ghc.Repositories.ListTrafficPaths(context.WithValue(ctx, github.SleepUntilPrimaryRateLimitResetWhenRateLimited, true), repo.GetOwner().GetLogin(), repo.GetName())
			if err != nil {
				log.Fatalln("Error getting paths traffic data: ", err)
			}
			for _, value := range paths {
				influxLine := fmt.Sprintf("github_stats_paths,repo=%s,path=%s count=%d,uniques=%d %v\n", repo.GetFullName(), *value.Path, *value.Count, *value.Uniques, time.Now().Unix())
				payload.WriteString(influxLine)
			}
		}(&payload)

		wg.Add(1)
		go func(payload *bytes.Buffer) {
			defer wg.Done()
			refs, _, err := ghc.Repositories.ListTrafficReferrers(context.WithValue(ctx, github.SleepUntilPrimaryRateLimitResetWhenRateLimited, true), repo.GetOwner().GetLogin(), repo.GetName())
			if err != nil {
				log.Fatalln("Error getting referrers traffic data: ", err)
			}
			for _, value := range refs {
				influxLine := fmt.Sprintf("github_stats_referrals,repo=%s,referrer=%s count=%d,uniques=%d %v\n", repo.GetFullName(), *value.Referrer, *value.Count, *value.Uniques, time.Now().Unix())
				payload.WriteString(influxLine)
			}
		}(&payload)

		wg.Add(1)
		go func(payload *bytes.Buffer) {
			defer wg.Done()
			views, _, err := ghc.Repositories.ListTrafficViews(context.WithValue(ctx, github.SleepUntilPrimaryRateLimitResetWhenRateLimited, true), repo.GetOwner().GetLogin(), repo.GetName(), nil)
			if err != nil {
				log.Fatalln("Error getting views traffic data: ", err)
			}
			for _, value := range views.Views {
				influxLine := fmt.Sprintf("github_stats_views,repo=%s count=%d,uniques=%d %v\n", repo.GetFullName(), *value.Count, *value.Uniques, value.Timestamp.Time.Unix())
				payload.WriteString(influxLine)
			}
		}(&payload)

		wg.Add(1)
		go func(payload *bytes.Buffer) {
			defer wg.Done()
			starsLine := fmt.Sprintf("github_stats_stars,repo=%s count=%d %v\n", repo.GetFullName(), *repo.StargazersCount, time.Now().Unix())
			payload.WriteString(starsLine)
			forksLine := fmt.Sprintf("github_stats_forks,repo=%s count=%d %v\n", repo.GetFullName(), *repo.ForksCount, time.Now().Unix())
			payload.WriteString(forksLine)
		}(&payload)

		wg.Add(1)
		go func(payload *bytes.Buffer) {
			defer wg.Done()
			workflows, _, err := ghc.Actions.ListWorkflows(context.WithValue(ctx, github.SleepUntilPrimaryRateLimitResetWhenRateLimited, true), repo.GetOwner().GetLogin(), repo.GetName(), nil)
			if err != nil {
				log.Fatalln("Error getting workflows: ", err)
			}
			for _, workflow := range workflows.Workflows {
				runs, _, err := ghc.Actions.ListWorkflowRunsByID(context.WithValue(ctx, github.SleepUntilPrimaryRateLimitResetWhenRateLimited, true), repo.GetOwner().GetLogin(), repo.GetName(), *workflow.ID, nil)
				if err != nil {
					log.Fatalln("Error getting workflow runs: ", err)
				}
				for _, run := range runs.WorkflowRuns {
					duration := run.UpdatedAt.GetTime().Sub(*run.RunStartedAt.GetTime()).Seconds()
					influxLine := fmt.Sprintf("github_stats_actions,repo=%s,workflow=%s duration=%.0f %v\n", repo.GetFullName(), escapeTagValue(*workflow.Name), duration, run.CreatedAt.GetTime().Unix())
					payload.WriteString(influxLine)
				}
			}
		}(&payload)

	}
	wg.Wait()

	if len(payload.Bytes()) == 0 {
		log.Fatalln("No data to send")
	}
	var buf bytes.Buffer
	w := gzip.NewWriter(&buf)
	w.Write(payload.Bytes())
	err = w.Close()
	if err != nil {
		log.Fatalln("Error compressing data: ", err)
	}
	url := fmt.Sprintf("https://%s/api/v2/write?precision=s&org=%s&bucket=%s", config.InfluxDBHost, config.Org, config.Bucket)
	post, _ := http.NewRequest("POST", url, &buf)
	post.Header.Set("Accept", "application/json")
	post.Header.Set("Authorization", "Token "+config.InfluxDBApiToken)
	post.Header.Set("Content-Encoding", "gzip")
	post.Header.Set("Content-Type", "text/plain; charset=utf-8")
	postResp, err := client.Do(post)
	if err != nil {
		log.Fatalln("Error sending data: ", err)
	}
	defer postResp.Body.Close()
	statusOK := resp.StatusCode >= http.StatusOK && resp.StatusCode < http.StatusMultipleChoices
	if !statusOK {
		body, err := io.ReadAll(postResp.Body)
		if err != nil {
			log.Fatalln("Error reading data: ", err)
		}
		log.Fatalln("Error sending data: ", postResp.Status, string(body))
	}
}
