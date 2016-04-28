package JAGC;
use Mojo::Base 'Mojolicious';

use Mango;
use Mango::BSON ':bson';
use Time::Piece;

use JAGC::Task::check;
use JAGC::Task::recheck;
use JAGC::Task::email;
use JAGC::Task::notice_new_task;
use JAGC::Task::notice_new_comment;
use JAGC::Task::notice_new_solution;

sub startup {
  my $app = shift;

  my $mode = $app->mode;
  $app->plugin('JAGC::Plugin::SendNotify');
  $app->plugin('JAGC::Plugin::Helpers');
  $app->plugin('Config', file => "app.$mode.conf");
  $app->plugin('Model');

  $app->secrets([$app->config->{secret}]);
  $app->sessions->cookie_name('jagc_session');
  $app->sessions->default_expiration(30 * 86400);

  $app->plugin(Minion => {Mango => $app->config->{mango}{uri}});
  $app->minion->add_task(check   => sub { JAGC::Task::check->new->call(@_) });
  $app->minion->add_task(recheck => sub { JAGC::Task::recheck->new->call(@_) });
  unless ($mode eq 'test') {
    $app->minion->add_task(email               => sub { JAGC::Task::email->new->call(@_) });
    $app->minion->add_task(notice_new_task     => sub { JAGC::Task::notice_new_task->new->call(@_) });
    $app->minion->add_task(notice_new_comment  => sub { JAGC::Task::notice_new_comment->new->call(@_) });
    $app->minion->add_task(notice_new_solution => sub { JAGC::Task::notice_new_solution->new->call(@_) });
  }

  push @{$app->commands->namespaces}, 'JAGC::Command';

  my $oid = qr/[0-9a-f]{24}/;
  my $num = qr/\d+/;

  my $r = $app->routes;
  $r->namespaces(['JAGC::Controller']);

  my $br = $r->under('/')->to('main#verify');

  $r->get('/')->to('main#index')->name('index');
  $br->get('/logout')->to('main#logout')->name('logout');
  $r->get('/tasks/:page' => [page => $num])->to('main#tasks', page => 1)->name('tasks');

  # Login
  $br->get('/login/twitter')->to('login#twitter')->name('login_twitter');
  $br->get('/login/vk')->to('login#vk')->name('login_vk');
  $br->get('/login/github')->to('login#github')->name('login_github');
  $br->get('/login/linkedin')->to('login#linkedin')->name('login_linkedin');
  $br->get('/login/fb')->to('login#fb')->name('login_fb');
  $br->get('/login/add')->to('login#add_social')->name('add_social');
  $br->get('/login/remove')->to('login#remove_social')->name('remove_social');

  # Admin
  my $admin = $r->under('/admin')->to('main#admin');
  $admin->get('index')->to('admin#index');

  $admin->post('/login/as')->to('login#as')->name('login_as');
  $br->get('/login/as')->to('login#as')->name('login_as');

  # Oauth
  $br->get('/oauth/github')->to('oauth#github');
  $br->get('/oauth/twitter')->to('oauth#twitter')->name('oauth_twitter');
  $br->get('/oauth/vk')->to('oauth#vk')->name('oauth_vk');
  $br->get('/oauth/linkedin')->to('oauth#linkedin')->name('oauth_linkedin');
  $br->get('/oauth/fb')->to('oauth#fb')->name('oauth_fb');
  $br->get('/oauth/test')->to('oauth#test')->name('oauth_test') if $mode eq 'test';

  # Contest
  $br->get('/contest/add')->to('contest#add_view')->name('contest_add_view');
  $br->post('/contest/add')->to('contest#upsert')->name('contest_add');
  $br->get('/contest/:con/edit' => [con => $oid])->to('contest#edit_view')->name('contest_edit_view');
  $br->post('/contest/:con/edit' => [con => $oid])->to('contest#upsert')->name('contest_edit');
  $br->get('/contest/:con/task/add' => [con => $oid])->to('task#add_view')->name('con_task_add_view');
  $br->post('/contest/:con/task/add' => [con => $oid])->to('task#add')->name('contest_task_add');
  $br->get('/contest/task/:id' => [id => $oid])->to('task#edit_view')->name('contest_task_edit_view');
  $br->get('/contest/:con/users/:page' => [con => $oid, page => $num])->to('user#all', page => 1)->name('contest_user_all');
  $br->get('/contests')->to('contest#contests')->name('contests');
  $br->get('/contest/:con' => [con => $oid] )->to('contest#view')->name('contest_view');
  $br->get('/contest/:con/:login' => [con => $oid])->to('contest#user_info')->name('contest_user_info');
  $br->get('/contest/:con/:login/events/:page' => [con => $oid, page => $num])->to('contest#events', page => 1)->name('contest_user_evt');

  $br->post('/task/add')->to('task#add')->name('task_add');
  $br->get('/task/add')->to('task#add_view')->name('task_add_view');
  $br->get('/task/:id'           => [id => $oid])->to('task#view', s => 1)->name('task_view');
  $br->get('/task/:id/incorrect' => [id => $oid])->to('task#view', s => 0)->name('task_view_incorrect');
  $br->get('/task/:tid/edit' => [tid => $oid])->to('task#edit_view')->name('task_edit_view');
  $br->post('/task/:tid/edit' => [tid => $oid])->to('task#edit')->name('task_edit');

  $br->get('/task/:id/solutions/:page' => [id => $oid, page => $num])
    ->to('task#view_solutions', s => 1, page => 1)->name('task_view_solutions');
  $br->get('/task/:id/incorrect/solutions/:page' => [id => $oid, page => $num])
    ->to('task#view_solutions', s => 0, page => 1)->name('task_view_incorrect_solutions');

  $br->get('/task/:id/comments' => [id => $oid])->to('task#comments')->name('task_comments');
  $br->post('/task/:id/comment' => [id => $oid])->to('task#comment_add')->name('comment_add');
  $br->get('/solution/:id/comments' => [id => $oid])->to('task#solution_comments')->name('solution_comments');
  $br->post('/solution/:id/comment' => [id => $oid])->to('task#solution_comment_add')
    ->name('solution_comment_add');
  $br->get('/comment/:id/delete' => [id => $oid])->to('task#comment_delete')->name('comment_delete');

  $br->post('/task/:id/solution/add/' => [id => $oid])->to('task#solution_add')->name('solution_add');

  $br->get('/user/:login')->to('user#info')->name('user_info');
  $br->get('/user/:login/tasks/owner')->to('user#tasks_owner')->name('user_tasks_owner');
  $br->get('/user/:login/settings')->to('user#settings')->name('user_settings');
  $br->get('/user/settings/notification/new')->to('user#notification_new')->name('user_notification_new');
  $br->get('/user/settings/notification/:tid/:type' => [tid => $oid, type => qr/comment|solution/])
    ->to('user#notification')->name('user_notification');
  $br->get('/register')->to('user#register_view')->name('user_register_view');
  $br->post('/user/register')->to('user#register')->name('user_register');
  $br->get('/users/:page' => [page => $num])->to('user#all', page => 1)->name('user_all');
  $br->post('/user/:login/change_name')->to('user#change_name')->name('user_change_name');

  $br->get('/user/:uid/confirmation/:email/code/:code' =>
      [uid => $oid, email => qr/.+@.+\.[^.]+/, code => qr/[0-9a-f]{32}/])->to('user#confirmation')
    ->name('user_confirmation');

  $br->get('/events/:page' => [page => $num, format => 0])->to('event#info', page => 1)->name('event_info');
  $br->get('/user/:login/events/:page' => [page => $num])->to('event#info', page => 1)
    ->name('event_user_info');

  $br->get('/about')->to('main#about')->name('about');
  $br->get('/paid')->to('main#paid')->name('paid');
  $br->get('/examples')->to('main#example')->name('examples');

  # RSS
  $r->get('/events' => [format => [qw/rss xml/]])->to('event#rss')->name('events_rss');

  *Mango::Database::c = \&Mango::Database::collection;
  $app->helper(
    db => sub {
      state $mango = Mango->new($app->config->{mango}{uri})->max_connections(10);
      return $mango->db;
    }
  );

  $app->helper(
    tz => sub {
      my ($c, $time) = @_;
      $time //= bson_time;
      my $tz = $c->cookie('tz') || 'Asia/Yekaterinburg';
      local $ENV{TZ} = $tz;
      my $ltime = localtime($time->to_epoch);
      return ($ltime->datetime, $ltime->cdate);
    }
  );

  $app->hook(
    before_routes => sub {
      my $c = shift;
      $c->req->url->base(Mojo::URL->new($app->config->{site_url})) unless $app->mode eq 'test';
    }
  );

  $app->defaults(user => '', max_int => 2147483647);

  $app->validator->add_check(
    code_size => sub {
      my ($validation, $name, $code, $min, $max) = @_;

      my $code_len = length $code;
      if ($code =~ m/^#!/) {
        $code =~ s/^#![^\s]+[\t ]*//;
        $code_len = length($code) - 1;
        $code_len++ unless $code =~ m/\n/;
      }
      return $code_len < $min || $code_len > $max;
    }
  );

  $app->validator->add_check(
    in => sub {
      my ($validation, $name, $value, $arr) = @_;
      $value eq $_ && return undef for @$arr;
      return 1;
    }
  );

  $app->validator->add_check(
    email => sub {
      my ($validation, $name, $value) = @_;
      return $value =~ m/.+\@.+\..+/ ? undef : 1;
    }
  );

  $app->validator->add_check(
    check_dates => sub {
      my $v = shift;

      my $start = $app->date_to_bson($v->param('start_date'));
      my $end   = $app->date_to_bson($v->param('end_date'));

      unless ($start) {
        $v->error(start_date => ['cechk_dates', q(Bad start date!)]);
        return undef;
      }

      unless ($end) {
        $v->error(end_date => ['check_dates', q(Bad end date!)]);
        return undef;
      }

      if ($end < $start) {
        $v->error(end_date => ['check_dates', q(Can't be smaller than start date!)]);
        return undef;
      }
      return undef;
    }
  );

  $app->validator->add_check(
    enough_tests => sub {
      my $v = shift;
      my @tests = grep { /^test_\d+_out/ } keys %{$v->input};
      $v->error(enough_tests => 'You need add at least 5 tests') if @tests < 5;

      return undef;
    }
  );
}

1;
