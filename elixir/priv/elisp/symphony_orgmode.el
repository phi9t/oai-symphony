(require 'json)
(require 'org)
(require 'org-id)
(require 'seq)
(require 'subr-x)

(defun symphony-orgmode-dispatch-json (request-base64)
  (let* ((json-object-type 'alist)
         (json-array-type 'list)
         (json-key-type 'string)
         (request (json-read-from-string (base64-decode-string request-base64))))
    (base64-encode-string
     (encode-coding-string
      (json-encode
       (condition-case err
           (symphony-orgmode--dispatch request)
         (error `((status . "error") (error . ,(error-message-string err))))))
      'utf-8)
     t)))

(defun symphony-orgmode--dispatch (request)
  (let ((file (symphony-orgmode--request request "file")))
    (with-current-buffer (find-file-noselect file)
      (org-mode)
      (save-excursion
        (save-restriction
          (widen)
          (let* ((state-map (symphony-orgmode--request request "state_map"))
                 (_todo-keywords (symphony-orgmode--apply-todo-keywords state-map))
                 (root-id (symphony-orgmode--request request "root_id"))
                 (root-pos (symphony-orgmode--root-position root-id))
                 (response
                  (pcase (symphony-orgmode--request request "action")
                    ("fetch_candidate_issues"
                     (symphony-orgmode--issues-by-states
                      root-pos
                      (symphony-orgmode--request request "states")
                      state-map))
                    ("fetch_issues_by_states"
                     (symphony-orgmode--issues-by-states
                      root-pos
                      (symphony-orgmode--request request "states")
                      state-map))
                    ("fetch_issue_states_by_ids"
                     (symphony-orgmode--issues-by-ids
                      root-pos
                      (symphony-orgmode--request request "ids")
                      state-map))
                    ("get_task"
                     (symphony-orgmode--task-data
                      (symphony-orgmode--task-position
                       root-pos
                       (symphony-orgmode--request request "task_id")
                       state-map)
                      state-map))
                    ("get_workpad"
                     `((content . ,(symphony-orgmode--workpad-content
                                    (symphony-orgmode--task-position
                                     root-pos
                                     (symphony-orgmode--request request "task_id")
                                     state-map)))))
                    ("replace_workpad"
                     `((content . ,(symphony-orgmode--replace-workpad
                                    (symphony-orgmode--task-position
                                     root-pos
                                     (symphony-orgmode--request request "task_id")
                                     state-map)
                                    (or (symphony-orgmode--request request "content") "")))))
                    ("set_state"
                     (symphony-orgmode--set-state
                      (symphony-orgmode--task-position
                       root-pos
                       (symphony-orgmode--request request "task_id")
                       state-map)
                      (symphony-orgmode--request request "state")
                      state-map))
                    (_ (error "invalid_action")))))
            (when (buffer-modified-p)
              (save-buffer))
            `((status . "ok") (data . ,response))))))))

(defun symphony-orgmode--request (request key)
  (cdr (assoc key request)))

(defun symphony-orgmode--apply-todo-keywords (state-map)
  (let ((keywords (mapcar #'car state-map)))
    (setq-local org-todo-keywords `((sequence ,@keywords)))
    (org-set-regexps-and-options)
    keywords))

(defun symphony-orgmode--root-position (root-id)
  (or (car
       (org-map-entries
        (lambda () (point))
        (format "ID=\"%s\"" root-id)
        'file))
      (error "root_not_found")))

(defun symphony-orgmode--task-positions (root-pos state-map)
  (save-excursion
    (goto-char root-pos)
    (delq nil
          (org-map-entries
           (lambda ()
             (unless (= (point) root-pos)
               (when (symphony-orgmode--heading-todo-keyword state-map)
                 (point-marker))))
           nil
           'tree))))

(defun symphony-orgmode--issues-by-states (root-pos states state-map)
  (let ((wanted (mapcar #'downcase states)))
    (delq nil
          (mapcar
           (lambda (task-pos)
             (let ((issue (symphony-orgmode--task-data task-pos state-map)))
               (when (member (downcase (or (cdr (assoc 'state issue)) "")) wanted)
                 issue)))
           (symphony-orgmode--task-positions root-pos state-map)))))

(defun symphony-orgmode--issues-by-ids (root-pos ids state-map)
  (let ((wanted (delete-dups (copy-sequence ids))))
    (delq nil
          (mapcar
           (lambda (task-id)
             (let ((task-pos (symphony-orgmode--task-position root-pos task-id state-map)))
               (when task-pos
                 (symphony-orgmode--task-data task-pos state-map))))
           wanted))))

(defun symphony-orgmode--task-position (root-pos task-id state-map)
  (or (seq-find
       (lambda (task-pos)
         (save-excursion
           (goto-char task-pos)
           (let* ((id (symphony-orgmode--ensure-id))
                  (custom-id (org-entry-get (point) "CUSTOM_ID"))
                  (identifier (or (org-entry-get (point) "SYMPHONY_IDENTIFIER") custom-id id)))
             (or (string= id task-id)
                 (and custom-id (string= custom-id task-id))
                 (and identifier (string= identifier task-id))))))
       (symphony-orgmode--task-positions root-pos state-map))
      (error "task_not_found")))

(defun symphony-orgmode--task-data (task-pos state-map)
  (save-excursion
    (goto-char task-pos)
    (let* ((id (symphony-orgmode--ensure-id))
           (custom-id (org-entry-get (point) "CUSTOM_ID"))
           (identifier (or (org-entry-get (point) "SYMPHONY_IDENTIFIER") custom-id id))
           (priority (symphony-orgmode--priority-value))
           (todo-keyword (symphony-orgmode--heading-todo-keyword state-map))
           (state (symphony-orgmode--display-state todo-keyword state-map)))
      `((id . ,id)
        (identifier . ,identifier)
        (title . ,(symphony-orgmode--heading-title state-map))
        (description . ,(symphony-orgmode--description))
        (priority . ,priority)
        (state . ,state)
        (branch_name . ,(org-entry-get (point) "SYMPHONY_BRANCH_NAME"))
        (url . ,(org-entry-get (point) "SYMPHONY_URL"))
        (labels . ,(mapcar #'downcase (org-get-tags nil t)))
        (blocked_by . ())
        (created_at . nil)
        (updated_at . nil)))))

(defun symphony-orgmode--ensure-id ()
  (or (org-entry-get (point) "ID")
      (let ((org-id-track-globally nil))
        (org-id-get-create))))

(defun symphony-orgmode--priority-value ()
  (pcase (org-entry-get (point) "PRIORITY")
    ("A" 1)
    ("B" 2)
    ("C" 3)
    (_ nil)))

(defun symphony-orgmode--display-state (todo-keyword state-map)
  (or (cdr (assoc todo-keyword state-map))
      todo-keyword
      ""))

(defun symphony-orgmode--heading-todo-keyword (state-map)
  (save-excursion
    (org-back-to-heading t)
    (beginning-of-line)
    (let* ((keywords (mapcar #'regexp-quote (mapcar #'car state-map)))
           (pattern (format "^\\*+\\s-+\\(%s\\)\\(?:\\s-+\\|$\\)" (string-join keywords "\\|"))))
      (when (looking-at pattern)
        (match-string-no-properties 1)))))

(defun symphony-orgmode--heading-title (state-map)
  (let ((title (org-get-heading t t t t))
        (todo-keyword (symphony-orgmode--heading-todo-keyword state-map)))
    (if (and todo-keyword
             (string-prefix-p (concat todo-keyword " ") title))
        (substring title (1+ (length todo-keyword)))
      title)))

(defun symphony-orgmode--description ()
  (save-excursion
    (let* ((body-start (progn (org-end-of-meta-data t) (point)))
           (subtree-end (save-excursion (org-end-of-subtree t t)))
           (content-end (save-excursion
                          (goto-char body-start)
                          (if (outline-next-heading)
                              (min (point) subtree-end)
                            subtree-end))))
      (let ((content (buffer-substring-no-properties body-start content-end)))
        (unless (string-empty-p (string-trim content))
          (string-trim-right content))))))

(defun symphony-orgmode--workpad-content (task-pos)
  (save-excursion
    (goto-char task-pos)
    (let ((workpad-pos (symphony-orgmode--direct-child-heading task-pos "Codex Workpad")))
      (if workpad-pos
          (symphony-orgmode--section-body workpad-pos)
        ""))))

(defun symphony-orgmode--replace-workpad (task-pos content)
  (save-excursion
    (goto-char task-pos)
    (let ((workpad-pos (or (symphony-orgmode--direct-child-heading task-pos "Codex Workpad")
                           (symphony-orgmode--insert-direct-child-heading task-pos "Codex Workpad"))))
      (symphony-orgmode--replace-section-body workpad-pos content)
      (symphony-orgmode--workpad-content task-pos))))

(defun symphony-orgmode--set-state (task-pos state-name state-map)
  (save-excursion
    (goto-char task-pos)
    (let ((todo-keyword (symphony-orgmode--todo-keyword-for-state state-name state-map)))
      (unless todo-keyword
        (error "state_not_found"))
      (symphony-orgmode--replace-todo-keyword todo-keyword)
      (symphony-orgmode--task-data task-pos state-map))))

(defun symphony-orgmode--todo-keyword-for-state (state-name state-map)
  (car
   (seq-find
    (lambda (entry)
      (string= (cdr entry) state-name))
    state-map)))

(defun symphony-orgmode--replace-todo-keyword (todo-keyword)
  (let ((current (save-excursion
                   (org-back-to-heading t)
                   (beginning-of-line)
                   (when (looking-at "^\\*+\\s-+\\([[:upper:]_]+\\)\\(?:\\s-+\\|$\\)")
                     (match-string-no-properties 1)))))
    (org-back-to-heading t)
    (beginning-of-line)
    (cond
     ((and current
           (re-search-forward (format "\\_<%s\\_>" (regexp-quote current)) (line-end-position) t))
      (replace-match todo-keyword t t))
     ((re-search-forward "^\\*+\\s-+" (line-end-position) t)
      (insert todo-keyword " "))
     (t
      (error "invalid_heading")))))

(defun symphony-orgmode--section-body (heading-pos)
  (save-excursion
    (goto-char heading-pos)
    (let* ((body-start (progn (org-end-of-meta-data t) (point)))
           (content-end (symphony-orgmode--section-content-end heading-pos))
           (content (buffer-substring-no-properties body-start content-end)))
      (string-trim-right content))))

(defun symphony-orgmode--replace-section-body (heading-pos content)
  (save-excursion
    (goto-char heading-pos)
    (let* ((body-start (progn (org-end-of-meta-data t) (point)))
           (content-end (symphony-orgmode--section-content-end heading-pos)))
      (delete-region body-start content-end)
      (goto-char body-start)
      (unless (string-empty-p content)
        (insert (string-trim-right content))
        (insert "\n")))))

(defun symphony-orgmode--section-content-end (heading-pos)
  (save-excursion
    (goto-char heading-pos)
    (let ((heading-level (org-outline-level))
          (limit (point-max))
          found)
      (outline-next-heading)
      (while (and (not found) (< (point) limit))
        (if (<= (org-outline-level) heading-level)
            (setq found (point))
          (outline-next-heading)))
      (or found limit))))

(defun symphony-orgmode--direct-child-heading (parent-pos title)
  (save-excursion
    (goto-char parent-pos)
    (let ((parent-level (org-outline-level))
          (subtree-end (save-excursion (org-end-of-subtree t t)))
          found)
      (outline-next-heading)
      (while (and (not found) (< (point) subtree-end))
        (let ((level (org-outline-level)))
          (cond
           ((<= level parent-level)
            (goto-char subtree-end))
           ((and (= level (1+ parent-level))
                 (string= (org-get-heading t t t t) title))
            (setq found (point)))
           (t
            (outline-next-heading)))))
      found)))

(defun symphony-orgmode--insert-direct-child-heading (parent-pos title)
  (save-excursion
    (goto-char parent-pos)
    (let ((parent-level (org-outline-level))
          (subtree-end (save-excursion (org-end-of-subtree t t))))
      (goto-char subtree-end)
      (unless (bolp)
        (insert "\n"))
      (let ((heading-pos (point)))
        (insert (make-string (1+ parent-level) ?*) " " title "\n\n")
        heading-pos))))
