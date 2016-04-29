$LOAD_PATH.unshift("/genealogy/lib")
require 'genealogy'

class NamesController < ApplicationController
  def index
    user = User.new username: "admin", password: "4zY!4*s#bPMO"
    user.openldap do
      @names = user.lastnames
    end
  end
end
