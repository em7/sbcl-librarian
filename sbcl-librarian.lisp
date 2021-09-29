(in-package #:sbcl-librarian)

;; Given a name denoting a type, return the C string denoting the type.
(defgeneric c-type (name))

(defmacro define-type-to-c (name c-name)
  `(defmethod c-type ((lisp-name (eql ',name))) ,c-name))

(define-type-to-c :int "int")
(define-type-to-c :unsigned-int "unsigned-int")
(define-type-to-c :string "char *")
(define-type-to-c :bool "int")
(define-type-to-c :float "float")
(define-type-to-c :double "double")
(define-type-to-c :void "void")

(sb-alien:define-alien-type :int sb-alien:int)
(sb-alien:define-alien-type :unsigned-int sb-alien:unsigned-int)
(sb-alien:define-alien-type :string sb-alien:c-string)
(sb-alien:define-alien-type :bool sb-alien:int)
(sb-alien:define-alien-type :float sb-alien:float)
(sb-alien:define-alien-type :double sb-alien:double)

;; Given a Lisp name denoting an alien type, return C code that will
;; define the type appropriately.
(defgeneric type-definition (lisp-name))

;; Given a Lisp form, wrap code mapping signalled Lisp conditions to
;; C-style return values around FORM using the given ERROR-MAP.
(defgeneric wrap-error-handling (form error-map))

;; Wrap an argument with code appropriate to its type.
(defgeneric wrap-argument-form (argument-form type) (:method (argument-form type) argument-form))
;; Wrap a result with code appropriate to its type.
(defgeneric wrap-result-form (result-form type) (:method (result-form type) result-form))

(defmacro define-handle-type (type-name c-type-name)
  (let ((lisp-name (gensym "LISP-NAME")))
    `(progn
       (define-type-to-c ,type-name ,c-type-name)
       (defmethod type-definition ((,lisp-name (eql ',type-name)))
         ,(format nil "typedef void* ~a;" c-type-name))
       (defmethod wrap-argument-form (argument-form (type (eql ',type-name)))
         `(dereference-handle ,argument-form))
       (defmethod wrap-result-form (result-form (type (eql ',type-name)))
         `(make-handle ,result-form))
       (eval-when (:compile-toplevel :load-toplevel :execute)
         (sb-alien:define-alien-type ,type-name (* t))))))

(defmacro define-enum-type (type-name c-type-name &rest enums)
  (let ((lisp-name (gensym "LISP-NAME")))
    `(progn
       (defmethod c-type ((,lisp-name (eql ',type-name))) ,c-type-name)
       (defmethod type-definition ((,lisp-name (eql ',type-name)))
         ,(format nil "typedef enum { ~:{~a = ~d, ~}} ~a;" enums c-type-name))
       ;; note: we could define this type as an alien enum, but
       ;; there's no reason to bother.
       (eval-when (:compile-toplevel :load-toplevel :execute)
         (sb-alien:define-alien-type ,type-name sb-alien:int)))))

  ;; mirrors handler case
(defmacro define-error-map (name error-type no-error &body cases)
  `(progn
     (defmethod wrap-error-handling (form (error-map (eql ',name)))
       `(handler-case (progn ,form ,,no-error)
          ,',@cases))
     (defmethod error-map-type ((error-map (eql ',name)))
       ',error-type)))

(defun c-to-lisp-name (c-name)
  (nsubstitute #\- #\_ (string-upcase c-name)))

(defun lisp-to-c-name (lisp-name)
  (nsubstitute #\_ #\- (string-downcase (symbol-name lisp-name))))

(defun callable-definitions-from-spec (function-prefix error-map specs)
  (let ((forms '()))
    (dolist (spec specs)
      (destructuring-bind (kind &rest things) spec
        (case kind
          (:function
           (dolist (spec things)
             (destructuring-bind (name result-type typed-lambda-list)
                 spec
               (let ((bindings
                       (mapcar (lambda (item)
                                 (destructuring-bind (arg type)
                                     item
                                   (list (gensym)
                                         (wrap-argument-form arg type))))
                               typed-lambda-list)))
                 (push `(sb-alien:define-alien-callable
                            ,(intern (concatenate 'string (c-to-lisp-name function-prefix) (symbol-name name)))
                            ,(error-map-type error-map)
                            (,@typed-lambda-list
                             ,@(unless (eq result-type :void)
                                 `((result (* ,result-type)))))
                          (let ,bindings
                            ,(wrap-error-handling
                              (let ((form (wrap-result-form
                                           `(,name ,@(mapcar #'first bindings))
                                           result-type)))
                                (if (eq result-type :void)
                                    form
                                    `(setf (sb-alien:deref result) ,form)))
                              error-map)))
                       forms))))))))
    (nreverse forms)))

(flet ((function-declaration (externp function-prefix name result-type typed-lambda-list error-map)
         (format nil "~a~a (*~a~a)(~{~a, ~}~a *result);"
                 (if externp "extern " "")
                 (c-type (error-map-type error-map))
                 function-prefix
                 (lisp-to-c-name name)
                 (mapcar (lambda (item)
                           (destructuring-bind (name type)
                               item
                             (format nil "~a ~a" (c-type type) (lisp-to-c-name name))))
                         typed-lambda-list)
                 (c-type result-type))))
  (defun header-emitter-from-specs (stream function-prefix error-map specs)
    (let ((forms '()))
      (flet ((output (string)
               (push `(format ,stream ,string) forms)
               (push `(terpri ,stream) forms)))
        (dolist (spec specs)
          (destructuring-bind (kind &rest things) spec
            (ecase kind
              (:literal
               (mapc #'output things))
              (:type
               (dolist (type things)
                 (output (type-definition type))))
              (:function
               (dolist (spec things)
                 (destructuring-bind (name result-type typed-lambda-list)
                     spec
                   (output (function-declaration t function-prefix name result-type typed-lambda-list error-map)))))))))
      (nreverse forms)))
  (defun source-emitter-from-specs (stream function-prefix error-map specs)
    (let ((forms '()))
      (flet ((output (string)
               (push `(format ,stream ,string) forms)
               (push `(terpri ,stream) forms)))
        (dolist (spec specs)
          (destructuring-bind (kind &rest things) spec
            (case kind
              (:function
               (dolist (spec things)
                 (destructuring-bind (name result-type typed-lambda-list)
                     spec
                   (output (function-declaration nil function-prefix name result-type typed-lambda-list error-map)))))))))
      (nreverse forms))))

(defmacro define-library (name (&key bindings-generator
                                     core-generator
                                     error-map
                                     (function-prefix ""))
                          &body specs)
  (let* ((c-name (lisp-to-c-name name))
         (core-name (concatenate 'string c-name ".core")))
    `(progn
       ,@(callable-definitions-from-spec function-prefix error-map specs)
       ,(when bindings-generator
          (let ((header-name (concatenate 'string c-name ".h"))
                (source-name (concatenate 'string c-name ".c")))
            `(defun ,bindings-generator (directory)
               (with-open-file (stream (merge-pathnames ,header-name directory)
                                       :direction :output
                                       :if-exists :supersede)
                 ,@(header-emitter-from-specs 'stream function-prefix error-map specs)
                 (format stream "extern void (*release_handle)(void *handle);~%")
                 (format stream "extern int ~ainit();" ,function-prefix))
               (with-open-file (stream (merge-pathnames ,source-name directory)
                                       :direction :output
                                       :if-exists :supersede)
                 (format stream "#include ~s~%" ,header-name)
                 ,@(source-emitter-from-specs 'stream function-prefix error-map specs)
                 (format stream "void (*release_handle)(void *handle);~%")
                 (format stream "extern int initialize_lisp(int argc, char **argv);~%")
                 (format stream "static char *init_args[] = {\"\", \"--core\", \"~a\", \"--noinform\"};~%"
                         ,core-name)
                 (format stream
                         "int ~ainit() { return initialize_lisp(4, init_args); }~%"
                         ,function-prefix)))))
       ,(when core-generator
          (let ((callable-exports '(release-handle)))
            (dolist (spec specs)
              (destructuring-bind (kind &rest things) spec
                (when (eq kind :function)
                  (dolist (spec things)
                    (push (intern (concatenate 'string
                                               (c-to-lisp-name function-prefix)
                                               (symbol-name (first spec))))
                          callable-exports)))))
            `(defun ,core-generator (directory)
               (sb-ext:save-lisp-and-die
                (merge-pathnames ,core-name directory)
                :callable-exports ',callable-exports)))))))