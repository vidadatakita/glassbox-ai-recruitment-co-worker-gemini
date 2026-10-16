# Be sure to restart your server when you modify this file.
#
# What never reaches a log (ONP-19: no personal data in logs; ids only). Rails' defaults cover
# passwords, tokens and emails. GlassBox adds the candidate's other personal fields and free text
# (name, phone, objection text, reasons, answers) and the offer code. Matching is partial, so
# :name also filters fields such as "name" inside lamaran[...].
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :name, :phone, :text, :reason, :answer, :code,
  # Feature 06: reviewer and calibration notes describe a candidate's CV; judgements hold CV
  # quotes. Also applied to SQL bind values in the log (Active Record filter_attributes), which is
  # what keeps job_applications.cv_text out of the log (:text covers cv_text).
  :note, :judgements, :quote,
  # Feature 08 (screening report): the S1 report fields quote the CV and describe the candidate;
  # the expected salary is the candidate's own figure. :reason already covers label_reason.
  :last_position, :education, :recent_experience, :narratives, :expected_salary,
  # D54: the candidate's city of residence.
  :domicile_city
]
