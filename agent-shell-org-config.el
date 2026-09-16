;;; agent-shell-org-config.el --- Define agent-shell agents in org-roam  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Aleksei Korolev

;; Author: Aleksei Korolev <lllshamanlll@gmail.com>
;; URL: https://github.com/lllShamanlll/agent-shell-org-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.62.1") (acp "0.13.1") (org-roam "2.2.2"))
;; Keywords: tools processes outlines

;; This package is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This package is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Keeps the whole definition of a containerized `agent-shell' agent in
;; org-roam, and adds those agents to the regular `agent-shell' agent
;; selection list.
;;
;; An *agent note* is an org-roam node tagged with
;; `agent-shell-org-config-tag' (":agent:" by default) holding named
;; source blocks:
;;
;;   #+NAME: dockerfile        (dockerfile) the image to build — required
;;   #+NAME: config            (elisp) extra runtime arguments, returns a
;;                             list of strings
;;   #+NAME: prerequisites     (elisp) run before the container starts
;;   #+NAME: postmortem        (elisp) run when the shell is killed
;;
;; Elisp blocks are evaluated with dynamic binding, in order, so
;; `prerequisites' can stash state in a global variable that `config'
;; and `postmortem' read back.
;;
;; A *project note* is an org-roam node tagged with
;; `agent-shell-org-config-project-tag' (":agent-project:" by default)
;; whose property drawer declares a project:
;;
;;   :ROOT:       ~/projects/myapp     ; mounted as the project — required
;;   :AGENT:      Claude Container    ; title of the agent note to default to
;;   :SKILL_TAGS: myapp               ; which skills the agent gets
;;
;; Project notes exist because a declared project may span several VCS
;; repositories: starting a shell anywhere under ROOT mounts ROOT
;; itself, not the inner repository that `project.el' would find.  The
;; deepest declared project containing the directory wins; without one,
;; the projectile or `project.el' root is mounted, as usual.
;;
;; A *skill note* is any org-roam node tagged with
;; `agent-shell-org-config-skill-tag' (":agent-skill:" by default) in
;; its "#+filetags:" line.  When the declared project lists SKILL_TAGS,
;; only skills carrying all of them are used.  Skills are hard-linked
;; (copied when hard-linking is not possible) into "notes/" of a fresh
;; session directory mounted into the container — turning them into
;; something the agent can use is the image's business.
;;
;; Usage: `M-x agent-shell' and pick the agent.  Agents defined in
;; org-roam appear alongside Claude, Gemini and the rest; when the
;; current directory belongs to a declared project naming an agent,
;; that agent is used without prompting.  When no declared project
;; covers the directory, you are offered to declare one — its root,
;; name and agent are all editable.  Declining runs a plain
;; `agent-shell' agent on the host, as if this package were not
;; installed.  Other commands:
;;
;;   M-x agent-shell-org-config-declare-project ; write a project note
;;   M-x agent-shell-org-config-new-shell     ; always prompt, ignoring AGENT
;;   M-x agent-shell-org-config-build         ; rebuild an agent's image
;;   M-x agent-shell-org-config-run-debug     ; shell into the container
;;   M-x agent-shell-org-config-list-skills   ; what would be mounted here
;;   M-x agent-shell-org-config-refresh-agents

;;; Code:

(require 'acp)
(require 'agent-shell)
(require 'compile)
(require 'org)
(require 'org-element)
(require 'org-id)
(require 'org-roam)
(require 'project)
(require 'seq)
(require 'subr-x)

(declare-function vterm "ext:vterm" (&optional buffer-name))
(declare-function vterm-send-string "ext:vterm" (string &optional paste-p))
(declare-function vterm-send-return "ext:vterm" ())
(declare-function projectile-project-root "ext:projectile" (&optional dir))
(defvar projectile-mode)

(defgroup agent-shell-org-config nil
  "Org-roam defined agents for `agent-shell'."
  :group 'agent-shell
  :prefix "agent-shell-org-config-")

;;; Customization

(defcustom agent-shell-org-config-tag "agent"
  "Tag marking org-roam nodes that define an agent."
  :type 'string
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-project-tag "agent-project"
  "Tag marking org-roam nodes that declare a project."
  :type 'string
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-skill-tag "agent-skill"
  "Tag marking org-roam notes handed to the agent as skills.
Only the \"#+filetags:\" line counts; a heading tagged with it does
not turn the whole file into a skill."
  :type 'string
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-offer-project-declaration t
  "Whether to offer declaring a project when none covers the directory.
Starting a shell somewhere no project note claims prompts for a
root, a name and an agent, and writes the project note.  Declining
starts a plain `agent-shell' agent on the host instead, and the
directory is not asked about again for the rest of the session."
  :type 'boolean
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-runtime "podman"
  "Container runtime executable."
  :type 'string
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-runtime-args '("run" "--rm" "--userns" "keep-id")
  "Arguments passed to `agent-shell-org-config-runtime' before the mounts.
Arguments returned by the agent note's config block are appended
after the mounts and the environment."
  :type '(repeat string)
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-session-mount "/data"
  "Where the session directory is mounted inside the container."
  :type 'string
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-project-mount "/project"
  "Where the project directory is mounted inside the container."
  :type 'string
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-mount-options ":Z"
  "Suffix appended to the -v mount specifications.
\":Z\" relabels for SELinux, \":z\" shares the label between
containers, \"\" leaves the labels alone."
  :type 'string
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-environment '(("INSIDE_CONTAINER" . "1"))
  "Environment variables set in the container, as (NAME . VALUE) pairs."
  :type '(alist :key-type string :value-type string)
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-acp-command '("claude-acp")
  "Command starting the ACP agent *inside* the container."
  :type '(repeat string)
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-image-prefix "agent-"
  "Prefix of the image name built from the agent note title."
  :type 'string
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-session-directory temporary-file-directory
  "Directory holding the per-session directories mounted into containers."
  :type 'directory
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-delete-session nil
  "Whether to delete the session directory once the shell is killed.
Keeping it around leaves the mounted skills available for inspection."
  :type 'boolean
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-build-on-launch 'missing
  "When to build an agent's image while starting its shell.

Building blocks Emacs, so the default only builds images that do
not exist yet.  Rebuild after editing a dockerfile block with
`agent-shell-org-config-build', which builds asynchronously.

  `missing' — build only when the image is not present
  t         — build every time a shell starts
  nil       — never build"
  :type '(choice (const :tag "Only when missing" missing)
                 (const :tag "Always" t)
                 (const :tag "Never" nil))
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-dockerfile-block "dockerfile"
  "Name of the source block holding the Dockerfile."
  :type 'string
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-arguments-block "config"
  "Name of the elisp block returning extra container arguments."
  :type 'string
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-prerequisites-block "prerequisites"
  "Name of the elisp block evaluated before the container starts."
  :type 'string
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-postmortem-block "postmortem"
  "Name of the elisp block evaluated when the shell is killed."
  :type 'string
  :group 'agent-shell-org-config)

(defconst agent-shell-org-config--elisp-languages '("elisp" "emacs-lisp")
  "Languages accepted for the evaluated blocks of an agent note.")

(defconst agent-shell-org-config--build-buffer "*Agent Image Build*"
  "Buffer showing image build output.")

;;; Source blocks

(defun agent-shell-org-config--block-value (file name &optional languages)
  "Return the body of the source block named NAME in FILE.
When LANGUAGES is non-nil, only consider blocks written in one of
them.  Returns nil when there is no such block."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((org-inhibit-startup t))
      (delay-mode-hooks (org-mode)))
    (org-element-map (org-element-parse-buffer) 'src-block
      (lambda (block)
        (when (and (equal name (org-element-property :name block))
                   (or (null languages)
                       (member (org-element-property :language block) languages)))
          (org-element-property :value block)))
      nil t)))

(defun agent-shell-org-config--eval-string (code)
  "Evaluate every form in CODE with dynamic binding, return the last value."
  (with-temp-buffer
    (insert code)
    (goto-char (point-min))
    (let ((result nil)
          (form nil)
          (done nil))
      (while (not done)
        (condition-case nil
            (setq form (read (current-buffer)))
          (end-of-file (setq done t)))
        (unless done
          ;; Dynamic binding on purpose: blocks of the same note share
          ;; state through global variables.
          (setq result (eval form))))
      result)))

(defun agent-shell-org-config--eval-block (file name)
  "Evaluate the elisp block named NAME in FILE, return its value.
Returns nil when FILE has no such block."
  (when-let ((code (agent-shell-org-config--block-value
                    file name agent-shell-org-config--elisp-languages)))
    (agent-shell-org-config--eval-string code)))

(defun agent-shell-org-config--eval-block-safely (file name)
  "Evaluate the elisp block named NAME in FILE, reporting errors.
Errors are turned into messages so that a failing block cannot take
down whatever ran it."
  (condition-case err
      (agent-shell-org-config--eval-block file name)
    (error (message "agent-shell-org-config: %s block failed: %s"
                    name (error-message-string err))
           nil)))

(defun agent-shell-org-config--dockerfile (file title)
  "Return the Dockerfile of the agent note FILE, titled TITLE."
  (or (agent-shell-org-config--block-value
       file agent-shell-org-config-dockerfile-block)
      (user-error "Note `%s' has no `%s' block"
                  title agent-shell-org-config-dockerfile-block)))

;;; Org-roam lookups

(defun agent-shell-org-config--files-with-tag (tag)
  "Return the files of org-roam nodes tagged TAG."
  (seq-uniq (mapcar #'car
                    (org-roam-db-query
                     [:select [file] :from nodes
                      :join tags :on (= nodes:id tags:node-id)
                      :where (= tags:tag $s1)]
                     tag))
            #'string=))

(defun agent-shell-org-config--nodes-with-tag (tag)
  "Return (TITLE FILE PROPERTIES) of the file-level nodes tagged TAG."
  (org-roam-db-query
   [:select [title file properties] :from nodes
    :join tags :on (= nodes:id tags:node-id)
    :where (and (= tags:tag $s1) (= nodes:level 0))]
   tag))

(defun agent-shell-org-config--property (properties name)
  "Return the NAME property from org-roam PROPERTIES, or nil when empty."
  (when-let ((value (cdr (assoc-string name properties t))))
    (unless (string-empty-p (string-trim value))
      (string-trim value))))

;;; Declared projects

(defun agent-shell-org-config--directory (path title)
  "Return PATH as an existing directory, declared by the project TITLE.
Environment variables and a leading \"/~/\" are resolved, so paths
written as \"~/projects/foo\" or \"/~/projects/foo\" both work.
Warns and returns nil when the result is not a directory."
  (let ((directory (directory-file-name
                    (file-truename
                     (expand-file-name (substitute-in-file-name path))))))
    (if (file-directory-p directory)
        directory
      (warn "Project `%s' declares ROOT `%s', which is not a directory"
            title path)
      nil)))

(defun agent-shell-org-config-projects ()
  "Return the declared projects as plists.
Each plist holds :title, :root, :agent and :skill-tags.  Notes
without a ROOT property are ignored."
  (delq nil
        (mapcar
         (lambda (row)
           (pcase-let ((`(,title ,_file ,properties) row))
             (when-let* ((declared (agent-shell-org-config--property properties "ROOT"))
                         (root (agent-shell-org-config--directory declared title)))
               (list :title title
                     :root root
                     :agent (agent-shell-org-config--property properties "AGENT")
                     :skill-tags
                     (when-let ((tags (agent-shell-org-config--property
                                       properties "SKILL_TAGS")))
                       (split-string tags "[ ,:]+" t))))))
         (agent-shell-org-config--nodes-with-tag
          agent-shell-org-config-project-tag))))

(defun agent-shell-org-config-project-at (directory)
  "Return the declared project containing DIRECTORY, if any.
When declared projects are nested, the deepest one wins."
  (let ((directory (file-name-as-directory
                    (file-truename (expand-file-name directory)))))
    (car (sort (seq-filter
                (lambda (project)
                  (string-prefix-p (file-name-as-directory (plist-get project :root))
                                   directory))
                (agent-shell-org-config-projects))
               (lambda (a b)
                 (> (length (plist-get a :root))
                    (length (plist-get b :root))))))))

(defun agent-shell-org-config--vcs-root (directory)
  "Return the project root DIRECTORY belongs to, ignoring declarations."
  (let ((default-directory (file-name-as-directory
                            (expand-file-name directory))))
    (directory-file-name
     (expand-file-name
      (or (and (bound-and-true-p projectile-mode)
               (fboundp 'projectile-project-root)
               (projectile-project-root))
          (when-let ((project (project-current)))
            (project-root project))
          default-directory)))))

(defun agent-shell-org-config-mount-root (directory)
  "Return the directory to mount as the project for DIRECTORY."
  (or (plist-get (agent-shell-org-config-project-at directory) :root)
      (agent-shell-org-config--vcs-root directory)))

;;; Declaring projects

(defconst agent-shell-org-config--no-agent-choice "(none, ask every time)"
  "Candidate standing for \"write no AGENT property\".")

(defun agent-shell-org-config-agent-titles ()
  "Return the titles of the agent notes."
  (mapcar #'car (agent-shell-org-config--nodes-with-tag
                 agent-shell-org-config-tag)))

(defun agent-shell-org-config--read-root (directory)
  "Read the root of a project covering DIRECTORY.
The proposed root is the one that would be mounted today, offered
as editable text.  Offers to create the directory when it does not
exist yet."
  (let ((root (directory-file-name
               (expand-file-name
                (read-directory-name
                 "Project root: "
                 (file-name-as-directory
                  (agent-shell-org-config--vcs-root directory)))))))
    (unless (file-directory-p root)
      (if (y-or-n-p (format "Directory %s does not exist.  Create it? "
                            (abbreviate-file-name root)))
          (make-directory root t)
        (user-error "Project root `%s' is not a directory"
                    (abbreviate-file-name root))))
    (directory-file-name (file-truename root))))

(defun agent-shell-org-config--read-agent ()
  "Read the title of the agent note a project defaults to.
Returns nil when no agent should be declared."
  (when-let ((titles (agent-shell-org-config-agent-titles)))
    (let* ((candidates (append titles
                               (list agent-shell-org-config--no-agent-choice)))
           (default (car titles))
           (choice (completing-read (format-prompt "Agent" default)
                                    candidates nil t nil nil default)))
      (unless (equal choice agent-shell-org-config--no-agent-choice)
        choice))))

(defun agent-shell-org-config--read-project (directory)
  "Read a project declaration covering DIRECTORY.
Returns the same plist as `agent-shell-org-config-projects'."
  (let* ((root (agent-shell-org-config--read-root directory))
         (title (read-string "Project name: " (file-name-nondirectory root)))
         (agent (agent-shell-org-config--read-agent))
         (skill-tags (split-string
                      (read-string "Skill tags (empty for every skill): ")
                      "[ ,:]+" t)))
    (when (string-empty-p (string-trim title))
      (user-error "A project needs a name"))
    (list :title (string-trim title)
          :root root
          :agent agent
          :skill-tags skill-tags)))

(defun agent-shell-org-config--write-project-note (project)
  "Write a project note declaring PROJECT, return its file.
PROJECT is a plist as returned by `agent-shell-org-config-projects'.
The note is written to `org-roam-directory', named the way org-roam
names its own, and added to the database right away, so the project
takes effect without waiting for a sync."
  (let* ((title (plist-get project :title))
         (file (expand-file-name
                (format "%s-%s.org"
                        (format-time-string "%Y%m%d%H%M%S")
                        (agent-shell-org-config--slug title))
                (file-name-as-directory
                 (expand-file-name org-roam-directory)))))
    (when (file-exists-p file)
      (user-error "Note `%s' already exists" (abbreviate-file-name file)))
    (with-temp-file file
      (insert ":PROPERTIES:\n"
              ":ID:         " (org-id-new) "\n"
              ":ROOT:       " (abbreviate-file-name (plist-get project :root)) "\n")
      (when-let ((agent (plist-get project :agent)))
        (insert ":AGENT:      " agent "\n"))
      (when-let ((skill-tags (plist-get project :skill-tags)))
        (insert ":SKILL_TAGS: " (string-join skill-tags " ") "\n"))
      (insert ":END:\n"
              "#+title: " title "\n"
              "#+filetags: :" agent-shell-org-config-project-tag ":\n"))
    (org-roam-db-update-file file)
    file))

(defvar agent-shell-org-config--declined nil
  "Roots declared projects were declined for, for this session.
Keeps the offer from coming back every time a shell is started in
a directory the user wants to run host agents in.")

(defun agent-shell-org-config--offer-project (directory)
  "Offer to declare a project covering DIRECTORY, return what came of it.
Returns the agent config of the declared project, the symbol
`declined' when the user refused, and nil when there was nothing
to offer or the new project names no agent."
  (let ((root (agent-shell-org-config--vcs-root directory)))
    (cond
     ((not agent-shell-org-config-offer-project-declaration) nil)
     ((agent-shell-org-config-project-at directory) nil)
     ((null (agent-shell-org-config-agent-titles)) nil)
     ((member root agent-shell-org-config--declined) 'declined)
     ((not (y-or-n-p (format "No project declares %s.  Declare one? "
                             (abbreviate-file-name root))))
      (push root agent-shell-org-config--declined)
      (message (concat "Running on the host; "
                       "M-x agent-shell-org-config-declare-project to declare one"))
      'declined)
     (t
      (let* ((project (agent-shell-org-config--read-project directory))
             (file (agent-shell-org-config--write-project-note project)))
        (message "Declared project `%s' in %s"
                 (plist-get project :title) (abbreviate-file-name file))
        (unless (agent-shell-org-config-project-at directory)
          (warn "Project `%s' does not cover %s, so it is not used here"
                (plist-get project :title) (abbreviate-file-name directory)))
        (agent-shell-org-config--declared-config directory))))))

;;; Skills

(defun agent-shell-org-config--skill-file-p (file)
  "Return non-nil when FILE carries the skill tag in its filetags line."
  (with-temp-buffer
    (insert-file-contents file nil 0 4096)
    (let* ((case-fold-search t)
           (first-heading (progn (goto-char (point-min))
                                 (or (re-search-forward "^\\*" nil t)
                                     (point-max)))))
      (goto-char (point-min))
      (re-search-forward (concat "^#[+]filetags:.*:"
                                 (regexp-quote agent-shell-org-config-skill-tag)
                                 ":")
                         first-heading t))))

(defun agent-shell-org-config-skill-files (&optional skill-tags)
  "Return the files of the skill notes to mount.
When SKILL-TAGS is non-nil, only skills carrying all of them qualify."
  (let ((files (seq-filter #'agent-shell-org-config--skill-file-p
                           (agent-shell-org-config--files-with-tag
                            agent-shell-org-config-skill-tag))))
    (dolist (tag skill-tags files)
      (let ((tagged (agent-shell-org-config--files-with-tag tag)))
        (setq files (seq-filter (lambda (file) (member file tagged)) files))))))

;;; Session

(defun agent-shell-org-config--slug (string)
  "Return STRING as a lowercase dash separated slug."
  (string-trim (downcase (replace-regexp-in-string "[^A-Za-z0-9]+" "-" string))
               "-+" "-+"))

(defun agent-shell-org-config--image-name (title)
  "Return the image name of the agent note titled TITLE."
  (concat agent-shell-org-config-image-prefix
          (agent-shell-org-config--slug title)))

(defun agent-shell-org-config--make-session (title skill-tags)
  "Create a session directory for the agent TITLE, holding SKILL-TAGS skills."
  (let* ((temporary-file-directory
          (file-name-as-directory
           (expand-file-name agent-shell-org-config-session-directory)))
         (session (file-name-as-directory
                   (make-temp-file
                    (format "agent-session-%s-" (agent-shell-org-config--slug title))
                    t)))
         (notes (file-name-as-directory (expand-file-name "notes" session))))
    (make-directory notes t)
    (dolist (file (agent-shell-org-config-skill-files skill-tags))
      (let ((destination (expand-file-name (file-name-nondirectory file) notes)))
        (condition-case nil
            (add-name-to-file (file-truename file) destination t)
          (error (copy-file file destination t)))))
    session))

(defun agent-shell-org-config--delete-session (session)
  "Delete the session directory SESSION, ignoring failures.
Skill notes are hard links, so the originals survive."
  (when (and session (file-directory-p session))
    (condition-case nil
        (delete-directory session t)
      (error (message "agent-shell-org-config: could not delete %s"
                      (abbreviate-file-name session))))))

;;; Images

(defun agent-shell-org-config--image-exists-p (image)
  "Return non-nil when IMAGE is present in the local image store."
  (zerop (call-process agent-shell-org-config-runtime nil nil nil
                       "image" "inspect" image)))

(defun agent-shell-org-config--make-context (dockerfile)
  "Return a fresh build context directory holding DOCKERFILE."
  (let ((context (file-name-as-directory (make-temp-file "agent-build-" t))))
    (with-temp-file (expand-file-name "Dockerfile" context)
      (insert dockerfile))
    context))

(defun agent-shell-org-config--build-synchronously (image dockerfile)
  "Build IMAGE from DOCKERFILE, blocking until it is done."
  (let ((context (agent-shell-org-config--make-context dockerfile))
        (buffer (get-buffer-create agent-shell-org-config--build-buffer)))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (let ((inhibit-read-only t))
              (erase-buffer)))
          (display-buffer buffer)
          (message "Building %s..." image)
          (let ((default-directory context))
            (unless (zerop (call-process agent-shell-org-config-runtime nil buffer t
                                         "build" "-t" image "."))
              (user-error "Build of %s failed, see %s"
                          image agent-shell-org-config--build-buffer)))
          (message "Building %s...done" image))
      (delete-directory context t))))

(defun agent-shell-org-config--build-asynchronously (image dockerfile &optional no-cache)
  "Build IMAGE from DOCKERFILE in a compilation buffer.
With NO-CACHE non-nil, build without reusing cached layers."
  (let* ((context (agent-shell-org-config--make-context dockerfile))
         (default-directory context)
         (command (format "%s build%s -t %s ."
                          (shell-quote-argument agent-shell-org-config-runtime)
                          (if no-cache " --no-cache" "")
                          (shell-quote-argument image)))
         (buffer (compilation-start
                  command nil
                  (lambda (_) agent-shell-org-config--build-buffer)))
         (process (get-buffer-process buffer))
         (watcher (lambda (process _event)
                    (unless (process-live-p process)
                      (delete-directory context t)
                      (unless (and (eq (process-status process) 'exit)
                                   (zerop (process-exit-status process)))
                        (message "Build of %s failed, see %s"
                                 image agent-shell-org-config--build-buffer))))))
    (with-current-buffer buffer
      (setq-local compilation-scroll-output t))
    (if (process-sentinel process)
        (add-function :after (process-sentinel process) watcher)
      (set-process-sentinel process watcher))
    buffer))

(defun agent-shell-org-config--ensure-image (image file title)
  "Make sure IMAGE exists, building it from the agent note FILE titled TITLE.
Honors `agent-shell-org-config-build-on-launch'."
  (pcase agent-shell-org-config-build-on-launch
    ('nil nil)
    ('missing (unless (agent-shell-org-config--image-exists-p image)
                (agent-shell-org-config--build-synchronously
                 image (agent-shell-org-config--dockerfile file title))))
    (_ (agent-shell-org-config--build-synchronously
        image (agent-shell-org-config--dockerfile file title)))))

;;; Container command

(defun agent-shell-org-config--mount (host container)
  "Return a -v argument mounting HOST at CONTAINER."
  (concat (directory-file-name (expand-file-name host)) ":" container
          agent-shell-org-config-mount-options))

(defun agent-shell-org-config--command (image project session file)
  "Return the runtime command running IMAGE for the agent note FILE.
PROJECT and SESSION are the host directories to mount.  The command
stops at the image name, so a command to run inside the container
can be appended."
  (append (list agent-shell-org-config-runtime)
          agent-shell-org-config-runtime-args
          (list "-v" (agent-shell-org-config--mount
                      session agent-shell-org-config-session-mount)
                "-v" (agent-shell-org-config--mount
                      project agent-shell-org-config-project-mount))
          (seq-mapcat (lambda (variable)
                        (list "-e" (format "%s=%s" (car variable) (cdr variable))))
                      agent-shell-org-config-environment)
          (agent-shell-org-config--eval-block
           file agent-shell-org-config-arguments-block)
          (list image)))

;;; Shell integration

(defvar-local agent-shell-org-config--file nil
  "File of the org-roam note defining this buffer's agent.")

(defvar-local agent-shell-org-config--project nil
  "Host directory mounted as the project in this buffer's container.")

(defvar-local agent-shell-org-config--session nil
  "Session directory mounted into this buffer's container.")

(defun agent-shell-org-config--resolve-path (path)
  "Map PATH from the mounted project directory into the container."
  (if (and agent-shell-org-config--project
           (string-prefix-p agent-shell-org-config--project path))
      (concat agent-shell-org-config-project-mount
              (substring path (length agent-shell-org-config--project)))
    path))

(defun agent-shell-org-config--teardown ()
  "Run the agent's postmortem block and clean its session up."
  (when agent-shell-org-config--file
    (agent-shell-org-config--eval-block-safely
     agent-shell-org-config--file
     agent-shell-org-config-postmortem-block))
  (when agent-shell-org-config-delete-session
    (agent-shell-org-config--delete-session agent-shell-org-config--session)))

(defun agent-shell-org-config--prepare (title file buffer)
  "Prepare BUFFER to run the agent titled TITLE, defined by FILE.
Creates the session, builds the image if needed and evaluates the
agent's prerequisites.  Does nothing when BUFFER is already prepared."
  (with-current-buffer buffer
    (unless agent-shell-org-config--session
      (let* ((project (agent-shell-org-config-project-at default-directory))
             (root (or (plist-get project :root)
                       (agent-shell-org-config--vcs-root default-directory)))
             (session (agent-shell-org-config--make-session
                       title (plist-get project :skill-tags))))
        (setq-local agent-shell-org-config--file file)
        (setq-local agent-shell-org-config--project root)
        (setq-local agent-shell-org-config--session session)
        (setq-local agent-shell-path-resolver-function
                    #'agent-shell-org-config--resolve-path)
        (add-hook 'kill-buffer-hook #'agent-shell-org-config--teardown nil t)
        (agent-shell-org-config--ensure-image
         (agent-shell-org-config--image-name title) file title)
        (agent-shell-org-config--eval-block
         file agent-shell-org-config-prerequisites-block)))))

(defun agent-shell-org-config--make-client (title file buffer)
  "Return an ACP client running the agent titled TITLE in its container.
FILE is the agent note, BUFFER the shell the client belongs to."
  (agent-shell-org-config--prepare title file buffer)
  (let ((command (agent-shell-org-config--command
                  (agent-shell-org-config--image-name title)
                  (buffer-local-value 'agent-shell-org-config--project buffer)
                  (buffer-local-value 'agent-shell-org-config--session buffer)
                  file)))
    (acp-make-client :command (car command)
                     :command-params (append (cdr command)
                                             agent-shell-org-config-acp-command)
                     :context-buffer buffer)))

(defun agent-shell-org-config--make-agent-config (title file)
  "Return an agent-shell configuration for the agent TITLE defined by FILE."
  (append
   (agent-shell-make-agent-config
    :identifier (intern (concat "org-" (agent-shell-org-config--slug title)))
    :mode-line-name title
    :buffer-name title
    :shell-prompt (format "%s> " title)
    :shell-prompt-regexp (concat (regexp-quote title) "> ")
    :client-maker (lambda (buffer)
                    (agent-shell-org-config--make-client title file buffer))
    :install-instructions
    (format "Install %s to run agents defined in org-roam."
            agent-shell-org-config-runtime))
   (list (cons :org-file file)
         (cons :org-title title))))

(defun agent-shell-org-config-agent-configs ()
  "Return an agent-shell configuration for every agent note."
  (mapcar (pcase-lambda (`(,title ,file ,_properties))
            (agent-shell-org-config--make-agent-config title file))
          (agent-shell-org-config--nodes-with-tag agent-shell-org-config-tag)))

(defvar agent-shell-org-config--registered nil
  "Entries this package last added to `agent-shell-agent-configs'.
Tracked by identity: entries of that list may be configuration
alists or functions returning one, so they cannot be told apart by
looking at them.")

;;;###autoload
(defun agent-shell-org-config-refresh-agents ()
  "Rebuild the org-roam defined entries of `agent-shell-agent-configs'."
  (interactive)
  (let ((agents (agent-shell-org-config-agent-configs)))
    (setq agent-shell-agent-configs
          (append agents
                  (seq-difference agent-shell-agent-configs
                                  agent-shell-org-config--registered
                                  #'eq)))
    (setq agent-shell-org-config--registered agents)
    (when (called-interactively-p 'interactive)
      (message "%d agent%s defined in org-roam"
               (length agents) (if (= 1 (length agents)) "" "s")))
    agents))

(defvar agent-shell-org-config--force-prompt nil
  "When non-nil, ignore the agent declared by the current project.")

(defun agent-shell-org-config--declared-config (directory)
  "Return the agent config declared by the project containing DIRECTORY.
Warns and returns nil when the project names an unknown agent."
  (when-let* ((project (agent-shell-org-config-project-at directory))
              (name (plist-get project :agent)))
    (or (seq-find (lambda (config) (equal name (map-elt config :org-title)))
                  agent-shell-org-config--registered)
        (progn
          (warn "Project `%s' declares unknown agent `%s'"
                (plist-get project :title) name)
          nil))))

(defun agent-shell-org-config--host-configs ()
  "Return the agent configs `agent-shell' knows that are not ours.
What the selection list would hold without this package."
  (let ((configs (if (functionp agent-shell-agent-configs)
                     (funcall agent-shell-agent-configs)
                   agent-shell-agent-configs)))
    (seq-difference configs agent-shell-org-config--registered #'eq)))

(defun agent-shell-org-config--select-config (original &rest args)
  "Select the agent declared by the current project, or call ORIGINAL with ARGS.
When no project covers the current directory, offer to declare
one; refusing hands the selection back to `agent-shell' with the
org-roam agents taken out, so the agent runs on the host."
  (condition-case err
      (agent-shell-org-config-refresh-agents)
    (error (message "agent-shell-org-config: could not read org-roam: %s"
                    (error-message-string err))))
  (if agent-shell-org-config--force-prompt
      (apply original args)
    (or (agent-shell-org-config--declared-config default-directory)
        (pcase (agent-shell-org-config--offer-project default-directory)
          ('declined (let ((agent-shell-agent-configs
                            (agent-shell-org-config--host-configs)))
                       (apply original args)))
          ((and config (pred consp)) config)
          (_ (apply original args))))))

(advice-add 'agent-shell-select-config :around
            #'agent-shell-org-config--select-config)

;;; Commands

(defun agent-shell-org-config--read-node ()
  "Read an org-roam node defining an agent."
  (org-roam-node-read
   nil
   (lambda (node)
     (member agent-shell-org-config-tag (org-roam-node-tags node)))
   nil t))

;;;###autoload
(defun agent-shell-org-config-declare-project ()
  "Write a project note covering the current directory.
Prompts for the root to mount, the name of the project and the
agent it defaults to, all starting from what a shell would do
here today.  Visits the new note, so the rest of it can be
written.  Also clears a previous refusal to declare a project
here."
  (interactive)
  (let* ((directory default-directory)
         (project (agent-shell-org-config--read-project directory))
         (file (agent-shell-org-config--write-project-note project)))
    (setq agent-shell-org-config--declined
          (delete (agent-shell-org-config--vcs-root directory)
                  agent-shell-org-config--declined))
    (find-file file)
    (message "Declared project `%s'" (plist-get project :title))))

;;;###autoload
(defun agent-shell-org-config-new-shell ()
  "Start an agent shell, prompting even when the project declares an agent."
  (interactive)
  (let ((agent-shell-org-config--force-prompt t))
    (agent-shell-new-shell)))

;;;###autoload
(defun agent-shell-org-config-build (node &optional no-cache)
  "Build the container image of the agent defined by NODE.
The build runs asynchronously in a compilation buffer.

With a prefix argument, or NO-CACHE non-nil, build without reusing
cached layers.  Needed when a step fetches something that changes
without the Dockerfile changing, such as installing the latest
release of a package."
  (interactive (list (agent-shell-org-config--read-node) current-prefix-arg))
  (let* ((file (org-roam-node-file node))
         (title (org-roam-node-title node)))
    (agent-shell-org-config--build-asynchronously
     (agent-shell-org-config--image-name title)
     (agent-shell-org-config--dockerfile file title)
     no-cache)))

;;;###autoload
(defun agent-shell-org-config-run-debug (node)
  "Run the container of the agent defined by NODE in a vterm buffer.
The container is started without the ACP command, dropping into
whatever shell its entrypoint runs."
  (interactive (list (agent-shell-org-config--read-node)))
  (unless (require 'vterm nil t)
    (user-error "Debug runs need vterm"))
  (let* ((file (org-roam-node-file node))
         (title (org-roam-node-title node))
         (image (agent-shell-org-config--image-name title))
         (project (agent-shell-org-config-project-at default-directory))
         (root (or (plist-get project :root)
                   (agent-shell-org-config--vcs-root default-directory)))
         (session (agent-shell-org-config--make-session
                   title (plist-get project :skill-tags))))
    (agent-shell-org-config--ensure-image image file title)
    (agent-shell-org-config--eval-block
     file agent-shell-org-config-prerequisites-block)
    (vterm (format "*debug:%s*" image))
    (vterm-send-string
     (mapconcat #'shell-quote-argument
                (agent-shell-org-config--command image root session file) " "))
    (vterm-send-return)))

;;;###autoload
(defun agent-shell-org-config-list-skills ()
  "Show the skills a session started here would mount."
  (interactive)
  (let* ((project (agent-shell-org-config-project-at default-directory))
         (skill-tags (plist-get project :skill-tags))
         (files (agent-shell-org-config-skill-files skill-tags)))
    (with-current-buffer (get-buffer-create "*Agent Skills*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Project: %s\n" (or (plist-get project :title)
                                            "none declared")))
        (insert (format "Mounted: %s\n" (agent-shell-org-config-mount-root
                                         default-directory)))
        (insert (format "Skills:  :%s:%s\n\n"
                        agent-shell-org-config-skill-tag
                        (if skill-tags
                            (concat " + :" (string-join skill-tags ": :") ":")
                          "")))
        (if (null files)
            (insert "No matching skill notes.\n")
          (dolist (file (sort files #'string<))
            (insert (abbreviate-file-name file) "\n"))))
      (goto-char (point-min))
      (special-mode)
      (display-buffer (current-buffer)))))

(provide 'agent-shell-org-config)
;;; agent-shell-org-config.el ends here
