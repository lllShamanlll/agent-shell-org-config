;;; agent-shell-org-config.el --- Define agent-shell agents in org-roam  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Aleksei Korolev

;; Author: Aleksei Korolev <lllshamanlll@gmail.com>
;; URL: https://github.com/lllShamanlll/agent-shell-org-config
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.50.1") (org-roam "2.2.2"))
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
;; org-roam: the image, the container arguments, the session lifecycle
;; hooks and the skills the agent is given.
;;
;; An *agent note* is an org-roam node tagged with
;; `agent-shell-org-config-tag' (":agent:" by default) holding named
;; source blocks:
;;
;;   #+NAME: dockerfile        (dockerfile) the image to build — required
;;   #+NAME: config            (elisp) extra runtime arguments, returns a
;;                             list of strings
;;   #+NAME: prerequisites     (elisp) run before launching (ssh-agent,
;;                             credentials, …)
;;   #+NAME: postmortem        (elisp) run after the agent process exits
;;
;; Elisp blocks are evaluated with dynamic binding, in order, so
;; `prerequisites' can stash state in a global variable that `config'
;; and `postmortem' read back.
;;
;; A *skill note* is any org-roam node tagged with
;; `agent-shell-org-config-skill-tag' (":agent-skill:" by default) in
;; its "#+filetags:" line.  Skill notes are hard-linked (copied when
;; hard-linking is not possible) into "notes/" of a fresh session
;; directory, which is mounted into the container — what the container
;; does with them (tangling them into skill directories, say) is the
;; image's business.
;;
;; Usage:
;;
;;   M-x agent-shell-org-config-run           ; pick a note, build, launch
;;   C-u M-x agent-shell-org-config-run       ; run the container in vterm
;;   M-x agent-shell-org-config-run-debug     ; same, without the prefix arg
;;   M-x agent-shell-org-config-list-skills   ; what would be mounted
;;
;; The launched shell gets a buffer-local
;; `agent-shell-path-resolver-function' mapping host project paths to
;; their in-container location, so file links in the transcript work.

;;; Code:

(require 'agent-shell)
(require 'agent-shell-anthropic)
(require 'compile)
(require 'org)
(require 'org-element)
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
  "Tag marking org-roam nodes that define an agent.
Used to narrow the completion list of `agent-shell-org-config-run'.
Set to nil to offer every org-roam node."
  :type '(choice (const :tag "Offer every node" nil)
                 (string :tag "Tag"))
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-skill-tag "agent-skill"
  "Tag marking org-roam notes handed to the agent as skills.
Only the \"#+filetags:\" line counts; a heading tagged with it does
not turn the whole file into a skill."
  :type 'string
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
  "Where the host project directory is mounted inside the container."
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
  "Command starting the ACP agent *inside* the container.
Bound to `agent-shell-anthropic-claude-acp-command' while the shell
is created."
  :type '(repeat string)
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-image-prefix "agent-"
  "Prefix of the image name built from the agent note title."
  :type 'string
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-session-directory temporary-file-directory
  "Directory holding per-session directories (Dockerfile plus skills)."
  :type 'directory
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-delete-session nil
  "Whether to delete the session directory once the agent exits.
Keeping it around leaves the generated Dockerfile and the mounted
skills available for inspection."
  :type 'boolean
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
  "Name of the elisp block evaluated before launching the container."
  :type 'string
  :group 'agent-shell-org-config)

(defcustom agent-shell-org-config-postmortem-block "postmortem"
  "Name of the elisp block evaluated after the agent process exits."
  :type 'string
  :group 'agent-shell-org-config)

(defconst agent-shell-org-config--elisp-languages '("elisp" "emacs-lisp")
  "Languages accepted for the evaluated blocks of an agent note.")

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

(defun agent-shell-org-config-skill-files ()
  "Return the files of every org-roam note tagged as a skill."
  (seq-uniq
   (seq-filter
    #'agent-shell-org-config--skill-file-p
    (mapcar #'car
            (org-roam-db-query
             [:select [file] :from nodes
              :join tags :on (= nodes:id tags:node-id)
              :where (= tags:tag $s1)]
             agent-shell-org-config-skill-tag)))
   #'string=))

;;; Session

(defun agent-shell-org-config--slug (string)
  "Return STRING as a lowercase dash separated slug."
  (let ((slug (downcase (replace-regexp-in-string "[^A-Za-z0-9]+" "-" string))))
    (string-trim slug "-+" "-+")))

(defun agent-shell-org-config--make-session (title)
  "Create and return a fresh session directory for the agent named TITLE."
  (let* ((temporary-file-directory
          (file-name-as-directory
           (expand-file-name agent-shell-org-config-session-directory)))
         (session (file-name-as-directory
                   (make-temp-file
                    (format "agent-session-%s-" (agent-shell-org-config--slug title))
                    t)))
         (notes (file-name-as-directory (expand-file-name "notes" session))))
    (make-directory notes t)
    (dolist (file (agent-shell-org-config-skill-files))
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

;;; Container command

(defun agent-shell-org-config--mount (host container)
  "Return a -v argument mounting HOST at CONTAINER."
  (concat (directory-file-name (expand-file-name host)) ":" container
          agent-shell-org-config-mount-options))

(defun agent-shell-org-config--command (image project session file)
  "Return the runtime command running IMAGE for the agent note FILE.
PROJECT and SESSION are the host directories to mount."
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

;;; Build

(defun agent-shell-org-config--build (image session callback)
  "Build IMAGE from the Dockerfile in SESSION, then call CALLBACK.
CALLBACK is only called when the build succeeds."
  (let* ((default-directory session)
         (command (format "%s build -t %s ."
                          (shell-quote-argument agent-shell-org-config-runtime)
                          (shell-quote-argument image)))
         (buffer (compilation-start command nil (lambda (_) "*Agent Image Build*")))
         (process (get-buffer-process buffer))
         (watcher (lambda (process _event)
                    (unless (process-live-p process)
                      (if (and (eq (process-status process) 'exit)
                               (zerop (process-exit-status process)))
                          (funcall callback)
                        (message "Build of %s failed, see *Agent Image Build*"
                                 image))))))
    (with-current-buffer buffer
      (setq-local compilation-scroll-output t))
    (if (process-sentinel process)
        (add-function :after (process-sentinel process) watcher)
      (set-process-sentinel process watcher))
    buffer))

;;; Launch

(defvar agent-shell-org-config--pending nil
  "Plist describing the shell `agent-shell' is about to create.
Holds :project, :session and :file until the new agent-shell buffer
picks it up in `agent-shell-org-config--setup-shell'.")

(defvar-local agent-shell-org-config--project nil
  "Host project directory mounted into this buffer's container.")

(defvar-local agent-shell-org-config--session nil
  "Session directory mounted into this buffer's container.")

(defvar-local agent-shell-org-config--file nil
  "File of the org-roam note defining this buffer's agent.")

(defun agent-shell-org-config--resolve-path (path)
  "Map PATH from the host project directory into the container."
  (if (and agent-shell-org-config--project
           (string-prefix-p agent-shell-org-config--project path))
      (concat agent-shell-org-config-project-mount
              (substring path (length agent-shell-org-config--project)))
    path))

(defun agent-shell-org-config--teardown (buffer)
  "Run the postmortem block of BUFFER's agent and clean its session up."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when agent-shell-org-config--file
        (agent-shell-org-config--eval-block-safely
         agent-shell-org-config--file
         agent-shell-org-config-postmortem-block))
      (when agent-shell-org-config-delete-session
        (agent-shell-org-config--delete-session agent-shell-org-config--session)))))

(defun agent-shell-org-config--setup-shell ()
  "Configure the agent-shell buffer created for a pending launch."
  (when agent-shell-org-config--pending
    (let ((pending agent-shell-org-config--pending)
          (buffer (current-buffer)))
      (setq agent-shell-org-config--pending nil)
      (remove-hook 'agent-shell-mode-hook #'agent-shell-org-config--setup-shell)
      (setq-local agent-shell-org-config--project
                  (directory-file-name (plist-get pending :project)))
      (setq-local agent-shell-org-config--session (plist-get pending :session))
      (setq-local agent-shell-org-config--file (plist-get pending :file))
      (setq-local agent-shell-path-resolver-function
                  #'agent-shell-org-config--resolve-path)
      (when-let ((process (get-buffer-process buffer)))
        (let ((watcher (lambda (process _event)
                         (unless (process-live-p process)
                           (agent-shell-org-config--teardown buffer)))))
          (if (process-sentinel process)
              (add-function :after (process-sentinel process) watcher)
            (set-process-sentinel process watcher)))))))

(defun agent-shell-org-config--launch-in-vterm (image command)
  "Run COMMAND for IMAGE in a vterm buffer instead of an agent shell."
  (unless (require 'vterm nil t)
    (user-error "Debug mode needs vterm"))
  (vterm (format "*debug:%s*" image))
  (vterm-send-string (mapconcat #'shell-quote-argument command " "))
  (vterm-send-return))

(defun agent-shell-org-config--launch (image project session file debug)
  "Launch IMAGE as defined by the agent note FILE.
PROJECT and SESSION are the mounted host directories.  With DEBUG
non-nil the container is run in vterm rather than in an agent shell."
  (agent-shell-org-config--eval-block file agent-shell-org-config-prerequisites-block)
  (let ((command (agent-shell-org-config--command image project session file)))
    (if debug
        (agent-shell-org-config--launch-in-vterm image command)
      (let ((agent-shell-command-prefix command)
            (agent-shell-anthropic-claude-acp-command
             agent-shell-org-config-acp-command))
        (setq agent-shell-org-config--pending
              (list :project project :session session :file file))
        (add-hook 'agent-shell-mode-hook #'agent-shell-org-config--setup-shell)
        (unwind-protect
            (agent-shell-new-shell)
          ;; No shell was created (aborted agent selection, error, …).
          (when agent-shell-org-config--pending
            (setq agent-shell-org-config--pending nil)
            (remove-hook 'agent-shell-mode-hook
                         #'agent-shell-org-config--setup-shell)))))))

;;; Entry points

(defun agent-shell-org-config--read-node ()
  "Read an org-roam node defining an agent."
  (org-roam-node-read
   nil
   (when agent-shell-org-config-tag
     (lambda (node)
       (member agent-shell-org-config-tag (org-roam-node-tags node))))
   nil t))

(defun agent-shell-org-config--project-root ()
  "Return the host directory to mount as the agent's project."
  (expand-file-name
   (or (and (bound-and-true-p projectile-mode)
            (fboundp 'projectile-project-root)
            (projectile-project-root))
       (when-let ((project (project-current)))
         (project-root project))
       default-directory)))

;;;###autoload
(defun agent-shell-org-config-run (node &optional debug)
  "Build and launch the containerized agent defined by NODE.
NODE is an org-roam node holding the agent's Dockerfile and its
elisp blocks.  With a prefix argument, or DEBUG non-nil, the
container is run in a vterm buffer instead of an agent shell."
  (interactive (list (agent-shell-org-config--read-node) current-prefix-arg))
  (let* ((file (org-roam-node-file node))
         (title (org-roam-node-title node))
         (dockerfile (or (agent-shell-org-config--block-value
                          file agent-shell-org-config-dockerfile-block)
                         (user-error "Note `%s' has no `%s' block"
                                     title
                                     agent-shell-org-config-dockerfile-block)))
         (image (concat agent-shell-org-config-image-prefix
                        (agent-shell-org-config--slug title)))
         (project (agent-shell-org-config--project-root))
         (session (agent-shell-org-config--make-session title)))
    (with-temp-file (expand-file-name "Dockerfile" session)
      (insert dockerfile))
    (agent-shell-org-config--build
     image session
     (lambda ()
       (agent-shell-org-config--launch image project session file debug)))))

;;;###autoload
(defun agent-shell-org-config-run-debug (node)
  "Build the agent defined by NODE and run its container in vterm."
  (interactive (list (agent-shell-org-config--read-node)))
  (agent-shell-org-config-run node t))

;;;###autoload
(defun agent-shell-org-config-list-skills ()
  "Show the skill notes an agent session would be given."
  (interactive)
  (let ((files (agent-shell-org-config-skill-files)))
    (if (null files)
        (message "No org-roam note is tagged :%s:"
                 agent-shell-org-config-skill-tag)
      (with-current-buffer (get-buffer-create "*Agent Skills*")
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "%d notes tagged :%s:\n\n"
                          (length files) agent-shell-org-config-skill-tag))
          (dolist (file (sort files #'string<))
            (insert (abbreviate-file-name file) "\n")))
        (goto-char (point-min))
        (special-mode)
        (display-buffer (current-buffer))))))

(provide 'agent-shell-org-config)
;;; agent-shell-org-config.el ends here
