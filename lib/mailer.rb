require 'mail'

module Mailer
  module_function

  def configure!
    Mail.defaults do
      delivery_method :smtp,
        address:              ENV.fetch('SMTP_ADDR'),
        port:                 ENV.fetch('SMTP_PORT').to_i,
        user_name:            ENV.fetch('SMTP_USER'),
        password:             ENV.fetch('SMTP_PASSWORD'),
        authentication:       :plain,
        enable_starttls_auto: true
    end
  end

  def notify_owner(name:, email:, subject:, message:, ip:)
    from = ENV.fetch('MAIL_FROM')
    to   = ENV.fetch('MAIL_TO')
    subj = subject.to_s.strip.empty? ? 'Contact form submission' : subject.to_s.strip
    body = <<~BODY
      New contact form submission on asxp.io.

      From:    #{name} <#{email}>
      Subject: #{subj}
      IP:      #{ip}
      Time:    #{Time.now.utc.iso8601}

      ---
      #{message}
    BODY

    Mail.deliver do
      from       from
      to         to
      reply_to   email
      subject    "[asxp.io] #{subj}"
      body       body
    end
  end

  def confirm_visitor(name:, email:, subject:, message:)
    from = ENV.fetch('MAIL_FROM')
    to   = ENV.fetch('MAIL_TO')
    subj = subject.to_s.strip.empty? ? '(blank)' : subject.to_s.strip
    body = <<~BODY
      Hi #{name},

      Thanks for contacting IE Sergei Poljanski. I've received your message
      and will get back to you as soon as possible.

      For your records, here's what you sent:

      Subject: #{subj}

      #{message}

      --
      IE Sergei Poljanski
      ie@asxp.io · https://asxp.io
    BODY

    Mail.deliver do
      from       from
      to         email
      reply_to   to
      subject    'Thanks for contacting IE Sergei Poljanski'
      body       body
    end
  end
end
