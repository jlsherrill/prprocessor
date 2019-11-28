require 'sinatra'
require 'raven'
require 'json'
require 'openssl'
require 'yaml'

require File.join(File.dirname(__FILE__), 'redmine/issue')
require File.join(File.dirname(__FILE__), 'redmine/project')
require File.join(File.dirname(__FILE__), 'github/pull_request')
require File.join(File.dirname(__FILE__), 'github/status')
require File.join(File.dirname(__FILE__), 'repository')


post '/pull_request' do
  actions = {}

  request.body.rewind
  payload_body = request.body.read
  verify_signature(payload_body)

  event = request.env['HTTP_X_GITHUB_EVENT']
  halt unless ['pull_request', 'pull_request_review', 'pull_request_review_comment'].include?(event)

  payload = JSON.parse(payload_body)
  action = payload['action']
  event_act = "#{event}/#{action}"

  raise "unknown repo" unless payload['repository'] && (repo_name = payload['repository']['full_name'])
  raise "repo #{repo_name} not configured" if Repository[repo_name].nil?
  repo = Repository[repo_name]

  client = Octokit::Client.new(:access_token => ENV['GITHUB_OAUTH_TOKEN'])
  pull_request = PullRequest.new(repo, payload['pull_request'], client)

  halt if event == 'pull_request' && ['closed', 'labeled', 'unlabeled'].include?(action)
  halt if event_act == 'pull_request_review_comment/created'

  if ENV['REDMINE_API_KEY'] && !repo.redmine_project.nil?
    users = YAML.load_file('config/users.yaml')

    pull_request.issue_numbers.each do |issue_number|
      issue = Issue.new(issue_number)
      project = Project.new(issue.project)

      user_id = users[pull_request.author] if users.key?(pull_request.author)

      if !repo.project_allowed?(project.identifier)
        if ENV['GITHUB_OAUTH_TOKEN']
          pull_request.labels = ['Waiting on contributor']
        end
      elsif !issue.rejected?
        if issue.backlog? || issue.recycle_bin? || issue.version.nil?
          issue.set_triaged(false)
          issue.set_target_version(nil)
        end
        issue.add_pull_request(pull_request.raw_data['html_url']) unless pull_request.cherry_pick?
        issue.set_status(Issue::READY_FOR_TESTING) unless issue.closed?
        issue.set_assigned(user_id) unless user_id.nil? || user_id.empty? || issue.assigned_to
        begin
          issue.save!
          actions['redmine'] = true
        rescue RestClient::UnprocessableEntity => exception
          Raven.capture_exception(exception)
          puts "Failed to save issue #{issue} for PR #{pull_request}: #{exception.message}"
          actions['redmine'] = false
        end
      end
    end
  end

  if ENV['GITHUB_OAUTH_TOKEN']
    if repo.link_to_redmine?
      pull_request.add_issue_links
    end

    if event_act == 'pull_request/synchronize' && pull_request.waiting_for_contributor?
      if pull_request.not_yet_reviewed?
        pull_request.replace_labels(['Waiting on contributor'], ['Needs testing'])
      else
        pull_request.replace_labels(['Waiting on contributor'], ['Needs testing', 'Needs re-review'])
      end
    end

    pull_request.check_commits_style if repo.redmine_required? && (event_act == 'pull_request/opened' || event_act == 'pull_request/synchronize')

    pull_request.labels = ["Needs testing", "Not yet reviewed"] if event_act == 'pull_request/opened'

    if event_act == 'pull_request_review/submitted'
      if ['rejected', 'changes_requested'].include?(payload['review']['state'])
        pull_request.replace_labels(['Not yet reviewed', 'Needs re-review'], ['Waiting on contributor'])
      elsif payload['review']['state'] == 'approved'
        pull_request.replace_labels(['Not yet reviewed', 'Needs re-review'], [])
      end
    end

    if pull_request.dirty?
      message = <<EOM
@#{pull_request.author}, this pull request is currently not mergeable. Please rebase against the #{pull_request.target_branch} branch and push again.

If you have a remote called 'upstream' that points to this repository, you can do this by running:

```
    $ git pull --rebase upstream #{pull_request.target_branch}
```

---------------------------------------
This message was auto-generated by Foreman's [prprocessor](https://projects.theforeman.org/projects/foreman/wiki/PrProcessor)
EOM
      pull_request.replace_labels(['Needs testing', 'Needs re-review', 'Not yet reviewed'], ['Waiting on contributor'])
      pull_request.add_comment(message)
    end

    pull_request.set_path_labels(repo.path_labels) if repo.path_labels?
    pull_request.set_branch_labels(repo.branch_labels) if repo.branch_labels?

    actions['github'] = true
  end

  status 500 if actions.has_value?(false)
  actions.to_json
end

get '/status' do
  locals = {}
  locals[:github_secret] = ENV['GITHUB_SECRET_TOKEN'] ? true : false
  locals[:redmine_key] = ENV['REDMINE_API_KEY'] ? true : false
  locals[:github_oauth_token] = ENV['GITHUB_OAUTH_TOKEN'] ? true : false
  locals[:configured_repos] = Repository.all.keys
  locals[:rate_limit] = Status.new.rate_limit

  erb :status, :locals => locals
end

# Hash of Redmine projects to linked GitHub repos
get '/redmine_repos' do
  Repository.all.select { |repo,config| !config.redmine_project.nil? }.inject({}) do |output,(repo,config)|
    output[config.redmine_project] ||= {}
    output[config.redmine_project][repo] = config.branches
    output
  end.to_json
end

def verify_signature(payload_body)
  signature = 'sha1=' + OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), ENV['GITHUB_SECRET_TOKEN'], payload_body)
  return halt 500, "Signatures didn't match!" unless Rack::Utils.secure_compare(signature, request.env['HTTP_X_HUB_SIGNATURE'])
end
